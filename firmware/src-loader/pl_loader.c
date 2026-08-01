// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// Deferred PL loader. The PROG_B / PCFG_INIT handshake and the PCAP DMA transfer
// are ported from the Zynq-7000 FSBL (lib/sw_apps/zynq_fsbl/src/pcap.c:
// FabricInit / PcapLoadPartition), which is the authoritative full-bitstream
// sequence. Because the app -- not the FSBL -- programs the PL here, it must
// also do what the FSBL handoff normally does: enable the PS->PL level shifters
// and release the PL resets through the SLCR afterward, or the fabric loads but
// looks dead. See docs/boot.md.

#include "pl_loader.h"

#include "xparameters.h"
#include "xdevcfg.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "ff.h"

// --- SLCR (System Level Control) registers, Zynq-7000 ---
#define SLCR_UNLOCK       0xF8000008u
#define SLCR_UNLOCK_KEY   0x0000DF0Du
#define SLCR_LOCK         0xF8000004u
#define SLCR_LOCK_KEY     0x0000767Bu
#define SLCR_LVL_SHFTR_EN 0xF8000900u
#define SLCR_LVL_PS_PL    0x0000000Au // PS->PL shifters (FabricInit)
#define SLCR_LVL_ALL      0x0000000Fu // all shifters (post-config)
#define SLCR_FPGA_RST_CTRL 0xF8000240u // 0 = release all PL resets

// Marks the last (only) descriptor of a single-shot PCAP DMA.
#define PCAP_LAST_TRANSFER 1u

// Bounded spin for the PROG_B/INIT and PCFG-done polls (~seconds at 667 MHz);
// avoids coupling the loader to a timer. INIT settles in microseconds.
#define PL_POLL_LIMIT 200000000u

static XDcfg DcfgInst;
static FATFS  Fatfs;
static int    sd_mounted;

const char *pl_status_str(pl_status_t s)
{
    switch (s) {
    case PL_OK:           return "ok";
    case PL_ERR_SD_MOUNT: return "SD mount failed";
    case PL_ERR_OPEN:     return "bitstream not found on SD";
    case PL_ERR_READ:     return "SD read failed";
    case PL_ERR_EMPTY:    return "empty bitstream file";
    case PL_ERR_TOOBIG:   return "bitstream too large";
    case PL_ERR_DEVCFG:   return "devcfg init failed";
    case PL_ERR_FABRIC:   return "fabric init timeout";
    case PL_ERR_XFER:     return "PCAP transfer rejected";
    case PL_ERR_DMA:      return "PCAP DMA never done";
    case PL_ERR_DONE:     return "FPGA done never asserted";
    case PL_ERR_PCAP:     return "PCAP error flags set";
    default:              return "unknown";
    }
}

int pl_loader_init(void)
{
    // SDT flow: XDcfg_LookupConfig takes the controller base address.
    XDcfg_Config *cfg = XDcfg_LookupConfig(XPAR_XDEVCFG_0_BASEADDR);
    if (cfg == NULL)
        return -PL_ERR_DEVCFG;
    if (XDcfg_CfgInitialize(&DcfgInst, cfg, cfg->BaseAddr) != XST_SUCCESS)
        return -PL_ERR_DEVCFG;

    // Route configuration through PCAP (not ICAP).
    XDcfg_EnablePCAP(&DcfgInst);
    XDcfg_SetControlRegister(&DcfgInst, XDCFG_CTRL_PCAP_MODE_MASK);

    FRESULT fr = f_mount(&Fatfs, "0:/", 1);
    if (fr != FR_OK)
        return -PL_ERR_SD_MOUNT;
    sd_mounted = 1;
    return 0;
}

// PROG_B low->high handshake that clears the fabric and waits for PCFG_INIT.
// Verbatim in spirit from FSBL FabricInit(), timer replaced by a bounded spin.
static pl_status_t fabric_init(void)
{
    Xil_Out32(SLCR_UNLOCK, SLCR_UNLOCK_KEY);
    Xil_Out32(SLCR_LVL_SHFTR_EN, SLCR_LVL_PS_PL);

    u32 ctrl = XDcfg_ReadReg(DcfgInst.Config.BaseAddr, XDCFG_CTRL_OFFSET);

    // PROG_B high, then low -> triggers fabric clear.
    XDcfg_WriteReg(DcfgInst.Config.BaseAddr, XDCFG_CTRL_OFFSET,
                   ctrl | XDCFG_CTRL_PCFG_PROG_B_MASK);
    XDcfg_WriteReg(DcfgInst.Config.BaseAddr, XDCFG_CTRL_OFFSET,
                   ctrl & ~XDCFG_CTRL_PCFG_PROG_B_MASK);

    // Wait for PCFG_INIT to deassert (fabric cleared).
    u32 spin = 0;
    while (XDcfg_GetStatusRegister(&DcfgInst) & XDCFG_STATUS_PCFG_INIT_MASK) {
        if (++spin > PL_POLL_LIMIT)
            return PL_ERR_FABRIC;
    }

    // PROG_B high, then wait for PCFG_INIT to assert (fabric ready for data).
    XDcfg_WriteReg(DcfgInst.Config.BaseAddr, XDCFG_CTRL_OFFSET,
                   ctrl | XDCFG_CTRL_PCFG_PROG_B_MASK);
    spin = 0;
    while (!(XDcfg_GetStatusRegister(&DcfgInst) & XDCFG_STATUS_PCFG_INIT_MASK)) {
        if (++spin > PL_POLL_LIMIT)
            return PL_ERR_FABRIC;
    }
    return PL_OK;
}

// Enable all PS<->PL level shifters and release the PL resets -- the step the
// FSBL normally does at handoff. Without it the bitstream is live but the PL
// AXI/reset stays held and the fabric appears dead.
static void fabric_enable(void)
{
    Xil_Out32(SLCR_LVL_SHFTR_EN, SLCR_LVL_ALL);
    Xil_Out32(SLCR_FPGA_RST_CTRL, 0x0);
    Xil_Out32(SLCR_LOCK, SLCR_LOCK_KEY);
}

static pl_status_t pcap_program(const u32 *src, u32 words)
{
    // Clear any latched PCAP interrupt/error state.
    XDcfg_IntrClear(&DcfgInst, 0xFFFFFFFFu);

    pl_status_t st = fabric_init();
    if (st != PL_OK)
        return st;

    // Single-shot DMA: source = buffer|LAST, dest = invalid|LAST (bitstream).
    u8 *src_last = (u8 *)((UINTPTR)src | PCAP_LAST_TRANSFER);
    u8 *dst_last = (u8 *)((UINTPTR)XDCFG_DMA_INVALID_ADDRESS | PCAP_LAST_TRANSFER);
    if (XDcfg_Transfer(&DcfgInst, src_last, words, dst_last, 0,
                       XDCFG_NON_SECURE_PCAP_WRITE) != XST_SUCCESS)
        return PL_ERR_XFER;

    u32 spin = 0;
    while (!(XDcfg_IntrGetStatus(&DcfgInst) & XDCFG_IXR_DMA_DONE_MASK)) {
        if (++spin > PL_POLL_LIMIT)
            return PL_ERR_DMA;
    }
    spin = 0;
    while (!(XDcfg_IntrGetStatus(&DcfgInst) & XDCFG_IXR_PCFG_DONE_MASK)) {
        if (++spin > PL_POLL_LIMIT)
            return PL_ERR_DONE;
    }
    if (XDcfg_IntrGetStatus(&DcfgInst) & XDCFG_IXR_ERROR_FLAGS_MASK)
        return PL_ERR_PCAP;

    fabric_enable();
    return PL_OK;
}

int pl_loader_pl_configured(void)
{
    return (XDcfg_IntrGetStatus(&DcfgInst) & XDCFG_IXR_PCFG_DONE_MASK) ? 1 : 0;
}

pl_status_t pl_loader_load(const char *name, uint32_t *out_bytes)
{
    if (!sd_mounted) {
        if (f_mount(&Fatfs, "0:/", 1) != FR_OK)
            return PL_ERR_SD_MOUNT;
        sd_mounted = 1;
    }

    char path[32];
    // "0:/<name>.bin"
    int n = 0;
    const char *pfx = "0:/";
    for (const char *p = pfx; *p && n < (int)sizeof(path) - 5; p++) path[n++] = *p;
    for (const char *p = name; *p && n < (int)sizeof(path) - 5; p++) path[n++] = *p;
    path[n++] = '.'; path[n++] = 'b'; path[n++] = 'i'; path[n++] = 'n'; path[n] = '\0';

    FIL fil;
    if (f_open(&fil, path, FA_READ) != FR_OK)
        return PL_ERR_OPEN;

    uint32_t size = (uint32_t)f_size(&fil);
    if (size == 0)                { f_close(&fil); return PL_ERR_EMPTY; }
    if (size > PL_LOAD_BUF_MAX)   { f_close(&fil); return PL_ERR_TOOBIG; }

    u8 *buf = (u8 *)PL_LOAD_BUF_ADDR;
    UINT br = 0;
    FRESULT fr = f_read(&fil, buf, size, &br);
    f_close(&fil);
    if (fr != FR_OK || br != size)
        return PL_ERR_READ;

    // PCAP reads the buffer over its own DMA; make sure it is in DDR, not cache.
    Xil_DCacheFlushRange((UINTPTR)buf, size);

    // Round the word count up so a non-multiple-of-4 file still transfers whole.
    u32 words = (size + 3u) / 4u;
    pl_status_t st = pcap_program((const u32 *)buf, words);
    if (st == PL_OK && out_bytes)
        *out_bytes = size;
    return st;
}

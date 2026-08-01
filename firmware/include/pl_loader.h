// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// Deferred PL loader (step 2): program the PL from a bitstream file on the SD
// card via PCAP, from the running app -- the network is already up (GEM is MIO,
// independent of the PL). Zynq-7000 path: XDcfg (devcfg) + xilffs FatFs. See
// docs/deferred-boot.md.
#ifndef PL_LOADER_H
#define PL_LOADER_H

#include <stdint.h>

// Scratch DDR buffer for the raw bitstream. Both users' core0 DDR region runs
// 0x00100000..0x20000000; 0x18000000 (384 MB) is clear above the app/.bss/heap
// (which sit near the base, incl. the acquisition's 1 MB DMA staging buffers)
// and below core1 at 0x20000000. A full xc7z020 bitstream is ~3.9 MB; cap 8 MB.
#define PL_LOAD_BUF_ADDR 0x18000000u
#define PL_LOAD_BUF_MAX  0x00800000u

typedef enum {
    PL_OK           = 0,
    PL_ERR_SD_MOUNT = 1,  // f_mount failed (no card / not FAT)
    PL_ERR_OPEN     = 2,  // bitstream file not found on SD
    PL_ERR_READ     = 3,  // f_read short/failed
    PL_ERR_EMPTY    = 4,  // zero-length file
    PL_ERR_TOOBIG   = 5,  // file exceeds PL_LOAD_BUF_MAX
    PL_ERR_DEVCFG   = 6,  // XDcfg init failed
    PL_ERR_FABRIC   = 7,  // FabricInit (PROG_B/INIT handshake) timed out
    PL_ERR_XFER     = 8,  // XDcfg_Transfer rejected the request
    PL_ERR_DMA      = 9,  // DMA-done never asserted
    PL_ERR_DONE     = 10, // PCFG (FPGA) done never asserted
    PL_ERR_PCAP     = 11, // PCAP error flags set after transfer
} pl_status_t;

// Initialize XDcfg and mount the SD FAT volume. Call once at startup. Returns 0
// on success, negative pl_status_t on failure.
int pl_loader_init(void);

// Load "<name>.bin" (a PCAP-format bitstream, produced by
// `bootgen -process_bitstream bin`) from the SD card into the PL. On success
// *out_bytes gets the file size. Safe to call repeatedly (reconfigures the PL).
pl_status_t pl_loader_load(const char *name, uint32_t *out_bytes);

// 1 if a fabric is currently configured (devcfg PCFG_DONE) -- true for a
// baked-in bitstream at boot and after a successful load, false on a blank PL.
// Call only after a successful pl_loader_init(). Reads a PS register, so it
// never hangs (unlike touching an unconfigured PL AXI slave).
int pl_loader_pl_configured(void);

const char *pl_status_str(pl_status_t s);

#endif // PL_LOADER_H

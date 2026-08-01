// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// PS-side driver for the PL stimulus peripheral. Everything here is cold
// path: uploads are firmware-gated to acquisition-idle periods (R4), and the
// streaming loop never calls into this file.

#include "main.h"
#include "pl_stim.h"
#include "xil_io.h"
#include "sleep.h"

static inline void stim_wr(uint32_t off, uint32_t val) {
    Xil_Out32(STIM_BASE_ADDR + off, val);
}
static inline uint32_t stim_rd(uint32_t off) {
    return Xil_In32(STIM_BASE_ADDR + off);
}

// MODE holds fields owned by different commands (start mode, trigger config,
// idle flavour). Reads return the AXI-domain shadow inside stim_axi_regs, so
// read-modify-write never races the clock crossing, and the register itself
// stays the single source of truth (a PS-side shadow desyncs on anything else
// touching MODE and hides the desync from status readers).
static uint32_t stim_mode_rmw(uint32_t clear_mask, uint32_t set_mask) {
    uint32_t m = (stim_rd(STIM_REG_MODE) & ~clear_mask) | set_mask;
    stim_wr(STIM_REG_MODE, m);
    // Read back before any dependent CONTROL pulse: the read's AXI round trip
    // both flushes the posted write and outlasts the 2-FF config crossing --
    // a stronger ordering guarantee than a timed wait, and ~10x cheaper.
    (void)stim_rd(STIM_REG_MODE);
    return m;
}

// The engine only accepts start and maintenance pulses in its idle state; a
// pulse landing during the stop-drain or idle-sequence states (~tens of us)
// is discarded by design. Command handlers wait for full idle so a command
// ack means the command actually took effect.
static int stim_wait_engine_idle(uint32_t timeout_us) {
    for (uint32_t waited = 0; waited <= timeout_us; waited += 2) {
        uint32_t st = stim_rd(STIM_REG_STATUS);
        if (!(st & (STIM_STAT_RUNNING | STIM_STAT_BUSY | STIM_STAT_IDLE_SEQ)))
            return 0;
        usleep(2);
    }
    return -1;
}

// Upload session state (single TCP client, single-threaded dispatch; cleared
// on connection teardown so a dead client's session cannot be resumed)
static uint32_t upload_ptr = 0;
static uint32_t upload_remaining = 0;

void pl_stim_set_window(uint32_t start_index, uint32_t end_index) {
    stim_wr(STIM_REG_START_INDEX, start_index);
    stim_wr(STIM_REG_END_INDEX, end_index);
}

void pl_stim_set_loop(uint32_t loop_index, uint32_t frame_count) {
    stim_wr(STIM_REG_LOOP_INDEX, loop_index);
    stim_wr(STIM_REG_FRAME_COUNT, frame_count);
}

void pl_stim_set_rate(uint32_t k) {
    stim_wr(STIM_REG_RATE_K, k);
}

void pl_stim_set_trigger(uint32_t line, uint32_t pol, uint32_t mode,
                         uint32_t retrig, uint32_t arm, uint32_t min_pulse_us) {
    stim_wr(STIM_REG_MINPULSE, min_pulse_us * 84u);  // 84 MHz clocks
    stim_mode_rmw(STIM_MODE_HW_ARM | (3u << STIM_MODE_TRIG_SHIFT) |
                  STIM_MODE_TRIG_POL | (7u << STIM_MODE_LINE_SHIFT) |
                  STIM_MODE_RETRIG,
                  ((mode & 3u) << STIM_MODE_TRIG_SHIFT)
                | ((line & 7u) << STIM_MODE_LINE_SHIFT)
                | (pol ? STIM_MODE_TRIG_POL : 0)
                | (retrig ? STIM_MODE_RETRIG : 0)
                | (arm ? STIM_MODE_HW_ARM : 0));
}

void pl_stim_set_idle(uint32_t drive_codes, uint32_t codes) {
    stim_wr(STIM_REG_IDLE_CODES, codes);
    stim_mode_rmw(STIM_MODE_IDLE_CODES,
                  drive_codes ? STIM_MODE_IDLE_CODES : 0);
}

static int stim_start_common(int continuous) {
    stim_mode_rmw(STIM_MODE_CONTINUOUS, continuous ? STIM_MODE_CONTINUOUS : 0);
    // A start pulse is only honored from the engine's idle state; if the tail
    // of a previous run is still draining (~tens of us), wait it out rather
    // than ack a start the engine discarded.
    if (stim_wait_engine_idle(200) != 0)
        return -1;   // still running (or wedged): start while running is an error
    stim_wr(STIM_REG_CONTROL, STIM_CTL_START);
    // The status read's own AXI round trip outlasts the pulse crossing and
    // the sticky-flag return path, so no settle delay is needed.
    uint32_t st = stim_rd(STIM_REG_STATUS);
    return (st & STIM_STAT_STICKY_START) ? -1 : 0;
}

int pl_stim_start(int continuous) {
    return stim_start_common(continuous);
}

void pl_stim_stop(void) {
    stim_wr(STIM_REG_CONTROL, STIM_CTL_STOP);
}

int pl_stim_trigger_once(void) {
    return stim_start_common(0);
}

// Zero and power-down disarm the hardware trigger first: with a gate held
// active (or an edge arriving), the engine would otherwise restart the moment
// the safe state was reached -- exactly what these commands exist to prevent.
//
// Each writes a SINGLE one-shot CONTROL bit: the W1P bits cross the clock
// domain as independent toggles, so two bits written together can arrive a
// cycle apart and race the engine's stop-flavour latch. The lone bit is
// honored both mid-run (stop-latch) and from idle (maintenance frame); a
// pulse landing in the engine's brief drain/idle-sequence window is
// discarded, so after the engine settles the command is issued once more
// from certain idle -- re-parking an already-safe output is harmless, a
// dropped safety command is not.
static void stim_safe_state(uint32_t ctl_bit) {
    stim_mode_rmw(STIM_MODE_HW_ARM, 0);
    stim_wr(STIM_REG_CONTROL, ctl_bit);
    if (stim_wait_engine_idle(500) == 0) {
        stim_wr(STIM_REG_CONTROL, ctl_bit);
        stim_wait_engine_idle(500);
    }
}

void pl_stim_zero(void) {
    stim_safe_state(STIM_CTL_FORCE_ZERO);
}

void pl_stim_powerdown(void) {
    stim_safe_state(STIM_CTL_POWERDOWN);
}

int pl_stim_upload_begin(uint32_t start_index, uint32_t count) {
    if (count == 0 || start_index >= STIM_RAM_DEPTH ||
        count > STIM_RAM_DEPTH - start_index)
        return -1;
    if (stim_rd(STIM_REG_STATUS) & STIM_STAT_RUNNING)
        return -1;
    upload_ptr = start_index;
    upload_remaining = count;
    return 0;
}

void pl_stim_upload_abort(void) {
    upload_remaining = 0;
    upload_ptr = 0;
}

int pl_stim_upload_write2(uint32_t w0, uint32_t w1) {
    if (upload_remaining == 0)
        return -1;
    stim_wr(STIM_RAM_OFFSET + upload_ptr * 4u, w0);  // DMA-EXEMPT: stimulus upload is deliberately single-beat -- cold path, refused while acquisition streams (R4), chosen over a DMA/bulk path because the upload is cold and bounded
    upload_ptr++;
    upload_remaining--;
    if (upload_remaining > 0) {          // final odd word: w1 is padding
        stim_wr(STIM_RAM_OFFSET + upload_ptr * 4u, w1);
        upload_ptr++;
        upload_remaining--;
    }
    return 0;
}

// CRC32 (IEEE 802.3, zlib-compatible) over the RAM words as little-endian
// bytes. ~16K single-beat reads at worst -- milliseconds, cold path only.
static uint32_t crc32_update(uint32_t crc, uint32_t word) {
    crc = ~crc;
    for (int b = 0; b < 4; b++) {
        crc ^= (word >> (8 * b)) & 0xFF;
        for (int i = 0; i < 8; i++)
            crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

int pl_stim_crc32(uint32_t offset, uint32_t count, uint32_t *crc_out) {
    if (count == 0 || offset >= STIM_RAM_DEPTH ||
        count > STIM_RAM_DEPTH - offset)
        return -1;
    uint32_t crc = 0;
    for (uint32_t i = 0; i < count; i++)
        crc = crc32_update(crc, stim_rd(STIM_RAM_OFFSET + (offset + i) * 4u));  // DMA-EXEMPT: CRC readback, same 3.9 decision as the upload path
    *crc_out = crc;
    return 0;
}

void pl_stim_collect_status(stim_status_response_t *out) {
    out->status        = stim_rd(STIM_REG_STATUS);
    out->mode          = stim_rd(STIM_REG_MODE);
    out->rate_k        = stim_rd(STIM_REG_RATE_K);
    out->start_index   = stim_rd(STIM_REG_START_INDEX);
    out->end_index     = stim_rd(STIM_REG_END_INDEX);
    out->loop_index    = stim_rd(STIM_REG_LOOP_INDEX);
    out->frame_count   = stim_rd(STIM_REG_FRAME_COUNT);
    out->current_index = stim_rd(STIM_REG_CURRENT);
    out->completed     = ((uint64_t)stim_rd(STIM_REG_COMP_HI) << 32)
                       | stim_rd(STIM_REG_COMP_LO);
    out->ts_start      = ((uint64_t)stim_rd(STIM_REG_TS_START_HI) << 32)
                       | stim_rd(STIM_REG_TS_START_LO);
    out->ts_stop       = ((uint64_t)stim_rd(STIM_REG_TS_STOP_HI) << 32)
                       | stim_rd(STIM_REG_TS_STOP_LO);
    out->idle_codes    = stim_rd(STIM_REG_IDLE_CODES);
    out->ram_depth     = stim_rd(STIM_REG_RAM_DEPTH);
    out->version       = stim_rd(STIM_REG_VERSION);
}

// Boot: DAC soft-reset, then park the outputs in power-down (R22). Each
// maintenance frame takes ~5 us through the engine's idle sequencer; the
// sleeps are generous so the second command finds the engine idle again.
void pl_stim_boot_init(void) {
    stim_wr(STIM_REG_CONTROL, STIM_CTL_SOFT_RESET);
    stim_wait_engine_idle(100);
    stim_wr(STIM_REG_CONTROL, STIM_CTL_DAC_RESET);
    stim_wait_engine_idle(100);
    usleep(300);   // DAC POR after soft reset needs 250 us (datasheet 8.3.3)
    stim_wr(STIM_REG_CONTROL, STIM_CTL_POWERDOWN);
    stim_wait_engine_idle(100);
    stim_wr(STIM_REG_MODE, 0);
    stim_wr(STIM_REG_RATE_K, 8);   // default: mono 30 kS/s
}

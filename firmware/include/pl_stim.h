// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// PS-side driver for the PL stimulus peripheral (stim_top): DAC70502
// waveform playback out of the 16384-frame PL RAM. Register map mirrors
// programmable_logic/src/stim_axi_regs.sv; the wire protocol and semantics are
// docs/stim.md. All of this is cold path -- nothing here may
// be called from the per-sample streaming loop.
#ifndef PL_STIM_H
#define PL_STIM_H

#include <stdint.h>

#define STIM_BASE_ADDR        0x43C00000UL
#define STIM_RAM_OFFSET       0x10000UL
#define STIM_RAM_DEPTH        16384U

// Register byte offsets (stim_axi_regs.sv)
#define STIM_REG_CONTROL      0x00
#define STIM_REG_STATUS       0x04
#define STIM_REG_MODE         0x08
#define STIM_REG_RATE_K       0x0C
#define STIM_REG_START_INDEX  0x10
#define STIM_REG_END_INDEX    0x14
#define STIM_REG_LOOP_INDEX   0x18
#define STIM_REG_FRAME_COUNT  0x1C
#define STIM_REG_IDLE_CODES   0x20
#define STIM_REG_MINPULSE     0x24
#define STIM_REG_CURRENT      0x28
#define STIM_REG_COMP_LO      0x2C
#define STIM_REG_COMP_HI      0x30
#define STIM_REG_TS_START_LO  0x34
#define STIM_REG_TS_START_HI  0x38
#define STIM_REG_TS_STOP_LO   0x3C
#define STIM_REG_TS_STOP_HI   0x40
#define STIM_REG_RAM_DEPTH    0x44
#define STIM_REG_VERSION      0x48

// CONTROL one-shot bits
#define STIM_CTL_START        (1u << 0)
#define STIM_CTL_STOP         (1u << 1)
#define STIM_CTL_SOFT_RESET   (1u << 2)
#define STIM_CTL_CLEAR_STICKY (1u << 3)
#define STIM_CTL_FORCE_ZERO   (1u << 4)
#define STIM_CTL_POWERDOWN    (1u << 5)
#define STIM_CTL_DAC_RESET    (1u << 6)

// MODE fields
#define STIM_MODE_CONTINUOUS  (1u << 0)
#define STIM_MODE_HW_ARM      (1u << 1)
#define STIM_MODE_TRIG_SHIFT  2         // [3:2] 0 off, 1 edge, 2 gate
#define STIM_MODE_TRIG_POL    (1u << 4)
#define STIM_MODE_LINE_SHIFT  5         // [7:5]
#define STIM_MODE_RETRIG      (1u << 8)
#define STIM_MODE_IDLE_CODES  (1u << 9)

// STATUS bits
#define STIM_STAT_RUNNING     (1u << 0)
#define STIM_STAT_BUSY        (1u << 1)
#define STIM_STAT_ARMED       (1u << 2)
#define STIM_STAT_CFG_VALID   (1u << 3)
#define STIM_STAT_STICKY_RAM  (1u << 4)
#define STIM_STAT_STICKY_START (1u << 5)
#define STIM_STAT_IDLE_SEQ    (1u << 6)

// CMD_STIM_GET_STATUS reply -- 68 bytes, decoded by net.py STIM_STATUS_FORMAT
// '<8I3Q3I' (keep both in sync; the _Static_assert below is the tripwire).
typedef struct __attribute__((packed)) {
    uint32_t status;         // STATUS register bits above + digital_in[15:8]
    uint32_t mode;
    uint32_t rate_k;
    uint32_t start_index;
    uint32_t end_index;
    uint32_t loop_index;
    uint32_t frame_count;
    uint32_t current_index;
    uint64_t completed;
    uint64_t ts_start;
    uint64_t ts_stop;
    uint32_t idle_codes;
    uint32_t ram_depth;
    uint32_t version;
} stim_status_response_t;
_Static_assert(sizeof(stim_status_response_t) == 68,
               "stim status struct must stay 68 bytes (net.py STIM_STATUS_FORMAT)");

void pl_stim_boot_init(void);
void pl_stim_set_window(uint32_t start_index, uint32_t end_index);
void pl_stim_set_loop(uint32_t loop_index, uint32_t frame_count);
void pl_stim_set_rate(uint32_t k);
void pl_stim_set_trigger(uint32_t line, uint32_t pol, uint32_t mode,
                         uint32_t retrig, uint32_t arm, uint32_t min_pulse_us);
void pl_stim_set_idle(uint32_t drive_codes, uint32_t codes);
int  pl_stim_start(int continuous);
void pl_stim_stop(void);
int  pl_stim_trigger_once(void);
void pl_stim_zero(void);
void pl_stim_powerdown(void);
int  pl_stim_upload_begin(uint32_t start_index, uint32_t count);
int  pl_stim_upload_write2(uint32_t w0, uint32_t w1);
void pl_stim_upload_abort(void);
int  pl_stim_crc32(uint32_t offset, uint32_t count, uint32_t *crc_out);
void pl_stim_collect_status(stim_status_response_t *out);

#endif // PL_STIM_H

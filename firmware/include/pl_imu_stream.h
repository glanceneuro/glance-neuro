// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Continuous BNO055 readout: a non-blocking per-port state machine, clocked by
// main-loop passes, that reads quaternion + accel + gyro over the AXI IIC and
// emits one unified-format UDP datagram per fused sample (stream_type = 4).
//
// Never on the 30 kHz path: each pass costs at most a couple of AXI-Lite reads
// (an IIC status poll) while a transfer is in flight, and nothing when idle.
// The I2C transactions themselves run in the IIC core's hardware FIFOs -- the
// CPU only enqueues commands and drains results.
#ifndef PL_IMU_STREAM_H
#define PL_IMU_STREAM_H

#include <stdint.h>

// IMU stream packet (stream_type = 4): the 8-word unified common header, then
// 5 payload words = 10 little-endian int16s. Total 13 words / 52 bytes.
//   w1 TYPE_VER   stream_type=4 | version<<8 | port<<16   (flags bit 0 = port)
//   w2/w3         64-bit master timestamp, latched when the sample completes --
//                 same clock as the neural data (the point of on-board ingest)
//   w4 SEQ        per-port, +1 per acquired sample. A send that fails is NOT
//                 retried (the next sample is 10 ms away and fresher), so a
//                 host-visible SEQ gap is exactly a lost sample.
//   w5 AUX0       period_ms[15:0] | iic_errors[23:16] | send_drops[31:24]
//                 (both counters saturate at 255 -- health-at-a-glance)
//   w6 AUX1       calib_stat[7:0] (CALIB_STAT register, refreshed ~1 Hz; 0xFF
//                 until first read) | opr_mode[15:8]
//   payload       quat w,x,y,z (1/2^14), acc x,y,z (0.01 m/s^2),
//                 gyr x,y,z (1/16 deg/s)
#define STREAM_TYPE_IMU        4
#define IMU_PKT_PAYLOAD_WORDS  5
#define IMU_PKT_WORDS          (8 + IMU_PKT_PAYLOAD_WORDS)   // 13

#define IMU_STREAM_VERSION     0x494D5553   // "IMUS" (CMD_IMU_STREAM reply)

#define IMU_PERIOD_MS_DEFAULT  10           // BNO055 fusion output rate is 100 Hz
#define IMU_PERIOD_MS_MIN      10
#define IMU_PERIOD_MS_MAX      1000

// 12-byte CMD_IMU_STREAM reply.
typedef struct __attribute__((packed)) {
    uint32_t active_mask;   // ports streaming after this command (bit0 A, bit1 B)
    uint32_t period_ms;
    uint32_t version;       // IMU_STREAM_VERSION
} imu_stream_response_t;
_Static_assert(sizeof(imu_stream_response_t) == 12,
               "imu stream response must stay 12 bytes (net.py decode)");

// Create the stream's UDP pcb. Call once at boot, after lwip_init.
void pl_imu_stream_init(void);

// Reconfigure which ports stream (mask bit0 = A, bit1 = B -- an absolute set,
// not a toggle) at the given period. Newly started ports get a BLOCKING NDOF
// entry (~50 ms), so the caller must refuse this while neural streaming is
// active; already-running ports just retime. Ports whose IIC the fabric lacks
// are silently dropped from the mask. Returns the resulting active mask.
uint32_t pl_imu_stream_set(uint32_t mask, uint32_t period_ms);

// Stop everything (fabric teardown path -- pl_config_apply). Never blocks.
void pl_imu_stream_stop_all(void);

// Is this port's machine running? (Used to refuse one-shot IIC users --
// detect_imu / imu_read -- that would interleave with a transfer in flight.)
int pl_imu_stream_active(int port);
uint32_t pl_imu_stream_mask(void);
uint32_t pl_imu_stream_period_ms(void);   // the clamped, in-force period

// One pass of every active machine: at most one IIC status read + FIFO
// enqueue/drain per port, one UDP send on the pass a sample completes. Call
// from the main loop on an acquisition fabric.
void pl_imu_stream_service(void);

#endif // PL_IMU_STREAM_H

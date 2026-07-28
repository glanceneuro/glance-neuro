// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
//
// PS-side driver for the imu_detect_top PL peripheral (the detect bitstream).
// Triggers a two-port BNO055 presence probe and reads back the per-port result.
// Register map mirrors programmable_logic/src/imu_detect_top.sv.
#ifndef PL_IMU_DETECT_H
#define PL_IMU_DETECT_H

#include <stdint.h>

#define IMUDET_BASE_ADDR   0x43D00000UL   // detect-image AXI-Lite base (assign_bd_address)

#define IMUDET_REG_CONTROL  0x00   // W1P: [0] start
#define IMUDET_REG_STATUS   0x04   // RO:  [0] busy [1] done
#define IMUDET_REG_RESULT_A 0x08   // RO:  [0]present [1]ack [2]timeout [4:3]idle {scl,sda} [15:8]chip_id
#define IMUDET_REG_RESULT_B 0x0C
#define IMUDET_REG_VERSION  0x10   // RO:  0x494D5531 "IMU1"

#define IMUDET_STATUS_BUSY  (1u << 0)
#define IMUDET_STATUS_DONE  (1u << 1)

#define IMUDET_R_PRESENT    (1u << 0)
#define IMUDET_R_ACK        (1u << 1)
#define IMUDET_R_TIMEOUT    (1u << 2)
#define IMUDET_R_IDLE_SHIFT 3      // [4:3] = {scl_idle, sda_idle}
#define IMUDET_R_ID_SHIFT   8      // [15:8] = chip_id

// CMD_DETECT_IMU (0xB0) reply: two raw RESULT words + the version word.
// net.py decodes the bitfields (keep in sync with net.py detect_imu()).
typedef struct __attribute__((packed)) {
    uint32_t result_a;
    uint32_t result_b;
    uint32_t version;
} imu_detect_response_t;
_Static_assert(sizeof(imu_detect_response_t) == 12,
               "imu detect response must stay 12 bytes (net.py decode)");

// Run one two-port probe and fill `out`. Returns 0 on completion, -1 on
// timeout waiting for the PL to finish. Cold path: called only from the detect
// command handler, never from any streaming loop.
int pl_imu_detect_run(imu_detect_response_t *out);

#endif // PL_IMU_DETECT_H

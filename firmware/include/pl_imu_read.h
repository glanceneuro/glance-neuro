// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// One-shot BNO055 fusion-data read (NDOF mode) over a port's AXI IIC: put the
// chip in NDOF if it isn't already, then burst-read quaternion + accel + gyro
// (+ calibration status and die temperature). Cold path only -- every read is
// a blocking polled I2C transaction (~3 ms at 100 kHz), so the command handler
// must refuse it while streaming. The continuous low-rate ingestion design
// this is a stepping stone for lives in docs/imu-ingestion.md.
#ifndef PL_IMU_READ_H
#define PL_IMU_READ_H

#include <stdint.h>
#include "xil_types.h"   // UINTPTR (pl_imu_ndof_enter takes a controller base)

// BNO055 register map (page 0) -- data sheet section 4.3.
#define BNO055_REG_ACC_DATA   0x08  // 6 B: acc x/y/z, int16 LE, 1 LSB = 0.01 m/s^2
#define BNO055_REG_GYR_DATA   0x14  // 6 B: gyr x/y/z, int16 LE, 1 LSB = 1/16 deg/s
#define BNO055_REG_QUA_DATA   0x20  // 8 B: quat w/x/y/z, int16 LE, 1 = 2^14
#define BNO055_REG_TEMP       0x34  // 1 B: die temperature, degC
#define BNO055_REG_CALIB_STAT 0x35  // [7:6] sys [5:4] gyr [3:2] acc [1:0] mag; 3 = calibrated
#define BNO055_REG_OPR_MODE   0x3D  // low nibble selects the operation mode
#define BNO055_MODE_CONFIG    0x00
#define BNO055_MODE_NDOF      0x0C  // 9-DoF sensor fusion, 100 Hz output

// Status word bits in imu_sample_response_t.status; layout mirrors the
// detect result word so net.py can share decode helpers.
#define IMUREAD_R_OK        (1u << 0)  // sample fields are valid
#define IMUREAD_R_NOACK     (1u << 1)  // nothing answered at 0x28
#define IMUREAD_R_MODEFAIL  (1u << 3)  // chip ACKed but would not enter NDOF
#define IMUREAD_R_MODE_SHIFT 8         // [15:8] OPR_MODE read back post-setup
#define IMUREAD_R_SR_SHIFT   24        // [31:24] AXI IIC status reg (diagnostic)

#define IMUREAD_VERSION 0x494D5552     // "IMUR"

// 32-byte reply, decoded by net.py imu_read().
typedef struct __attribute__((packed)) {
    uint32_t status;                       // IMUREAD_R_* + mode + iic_sr
    int16_t  quat_w, quat_x, quat_y, quat_z;  // 1 unit = 1/16384
    int16_t  acc_x, acc_y, acc_z;             // 1 LSB = 0.01 m/s^2
    int16_t  gyr_x, gyr_y, gyr_z;             // 1 LSB = 1/16 deg/s
    uint8_t  calib_stat;                      // BNO055_REG_CALIB_STAT verbatim
    int8_t   temp_c;                          // die temperature, degC
    uint16_t reserved;                        // keep 4-byte alignment for version
    uint32_t version;                         // IMUREAD_VERSION
} imu_sample_response_t;
_Static_assert(sizeof(imu_sample_response_t) == 32,
               "imu sample response must stay 32 bytes (net.py decode)");

// Put the chip on this port's bus into NDOF (blocking, up to ~50 ms of mode-
// switch delays; a no-op when already there). Fills *mode_out with the mode
// read back. Returns 1 on success. The core at `base` must be DynInit'd.
int pl_imu_ndof_enter(UINTPTR base, uint8_t *mode_out);

// Read one fused sample from the given port (0 = A, 1 = B). The caller MUST
// have checked that the loaded fabric carries that port's AXI IIC (pl_has_iic_a
// / _b) -- touching an absent AXI slave hangs the core -- and that streaming is
// inactive (this blocks for milliseconds; mode entry adds ~50 ms on first use).
// Always fills *out (status says how far it got). Returns 1 when IMUREAD_R_OK.
int pl_imu_read_sample(int port, imu_sample_response_t *out);

#endif // PL_IMU_READ_H

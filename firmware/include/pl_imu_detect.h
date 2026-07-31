// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// PS-side driver for the IMU-detect image: two Xilinx AXI IIC controllers (one
// per headstage port) probe address 0x28 for a Bosch BNO055 and read its
// CHIP_ID. Silicon-proven I2C (clock stretching + real bus timing handled by
// the IP), driven with the standard XIic low-level API.
#ifndef PL_IMU_DETECT_H
#define PL_IMU_DETECT_H

#include <stdint.h>

#define IMUDET_A_BASE   0x43D00000UL   // axi_iic_a (port A), assign_bd_address
#define IMUDET_B_BASE   0x43D10000UL   // axi_iic_b (port B)

#define BNO055_I2C_ADDR 0x28
#define BNO055_CHIP_REG 0x00
#define BNO055_CHIP_ID  0xA0

#define IMUDET_VERSION  0x494D5532     // "IMU2" (axi_iic revision)

// Per-port result word (packed into the CMD_DETECT_IMU reply):
//   [0] present (device ACKed AND chip_id == 0xA0)
//   [1] ack     (device ACKed its address at 0x28)
//   [2] absent  (this port carries no AXI IIC on the loaded fabric -- it was NOT
//               probed, so the core is never left waiting on an absent AXI slave)
//   [15:8]  chip_id byte read back
//   [31:24] AXI IIC Status Register (post-init) — diagnostic. A live core reads
//           its reset value (~0xC0, both FIFOs empty); 0x00/0xFF means the base
//           address is wrong or the controller isn't there.
#define IMUDET_R_PRESENT (1u << 0)
#define IMUDET_R_ACK     (1u << 1)
#define IMUDET_R_ABSENT  (1u << 2)
#define IMUDET_R_ID_SHIFT 8
#define IMUDET_R_SR_SHIFT 24

// 12-byte reply, decoded by net.py detect_imu().
typedef struct __attribute__((packed)) {
    uint32_t result_a;
    uint32_t result_b;
    uint32_t version;
} imu_detect_response_t;
_Static_assert(sizeof(imu_detect_response_t) == 12,
               "imu detect response must stay 12 bytes (net.py decode)");

// Probe the ports whose AXI IIC the loaded fabric actually carries, and fill
// `out`. probe_a / probe_b MUST be false for a port whose IIC is absent (e.g. a
// 128-ch LVDS port on acq_imu_port_a/_b) -- reading a non-existent AXI slave
// never returns and hangs the core. A non-probed port reports IMUDET_R_ABSENT.
// Returns 0 always. Cold path: called only from the detect command handler.
int pl_imu_detect_run(imu_detect_response_t *out, int probe_a, int probe_b);

#endif // PL_IMU_DETECT_H

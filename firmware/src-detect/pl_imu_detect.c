// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University

#include "pl_imu_detect.h"
#include "xiic_l.h"

// Probe one port's AXI IIC master: write the CHIP_ID register pointer to the
// BNO055 at 0x28, then read one byte back. XIic_Send returns the number of
// bytes ACKed, so 0 means nothing answered at 0x28 (no device / no IMU).
static uint32_t probe_port(UINTPTR base)
{
    uint8_t reg = BNO055_CHIP_REG;
    uint8_t val = 0;
    uint32_t result = 0;

    unsigned sent = XIic_Send(base, BNO055_I2C_ADDR, &reg, 1, XIIC_STOP);
    if (sent == 1) {
        result |= IMUDET_R_ACK;                 // address ACKed -> a device is there
        unsigned rcvd = XIic_Recv(base, BNO055_I2C_ADDR, &val, 1, XIIC_STOP);
        if (rcvd == 1) {
            result |= ((uint32_t)val) << IMUDET_R_ID_SHIFT;
            if (val == BNO055_CHIP_ID)
                result |= IMUDET_R_PRESENT;
        }
    }
    return result;
}

int pl_imu_detect_run(imu_detect_response_t *out)
{
    out->result_a = probe_port(IMUDET_A_BASE);
    out->result_b = probe_port(IMUDET_B_BASE);
    out->version  = IMUDET_VERSION;
    return 0;
}

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University

#include "pl_imu_detect.h"
#include "xiic_l.h"

// Probe one port's AXI IIC master for a BNO055 CHIP_ID.
//
// XIic_DynInit() soft-resets the core and puts it in dynamic mode (the plain
// XIic_Send/XIic_Recv assume an already-initialised core, which is why the
// first cut saw no transactions at all). Then a dynamic write of the register
// pointer with a repeated start, and a 1-byte read. XIic_DynSend returns the
// number of bytes ACKed -> 0 means nothing answered at 0x28.
//
// The core's Status Register (post-init) is folded into the result as a
// diagnostic: a live controller reads its reset SR (~0xC0, both FIFOs empty);
// 0x00 / 0xFF would mean the base address or the controller is wrong.
static uint32_t probe_port(UINTPTR base)
{
    uint32_t result = 0;

    XIic_DynInit(base);
    uint32_t sr = XIic_ReadReg(base, XIIC_SR_REG_OFFSET) & 0xFF;
    result |= (sr << IMUDET_R_SR_SHIFT);

    uint8_t reg = BNO055_CHIP_REG;
    uint8_t val = 0;
    unsigned sent = XIic_DynSend(base, BNO055_I2C_ADDR, &reg, 1, XIIC_REPEATED_START);
    if (sent == 1) {
        result |= IMUDET_R_ACK;
        unsigned rcvd = XIic_DynRecv(base, BNO055_I2C_ADDR, &val, 1);
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

// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University

#include "pl_imu_read.h"
#include "pl_imu_detect.h"   // IMUDET_*_BASE, BNO055_I2C_ADDR
#include "xiic_l.h"
#include "sleep.h"

// The BNO055 needs time to switch operation modes (data sheet table 3-6):
// 19 ms into CONFIG, 7 ms out of it. Rounded up generously -- this runs once
// per mode entry on a cold path, not per sample.
#define BNO055_TO_CONFIG_MS  25
#define BNO055_FROM_CONFIG_MS 20

// Register-pointer write with repeated start, then an n-byte read. Same
// dynamic-mode sequence pl_imu_detect.c proved on silicon (a plain
// XIic_Send/Recv on an uninitialised core drives nothing).
static int bno_read(UINTPTR base, uint8_t reg, uint8_t *buf, unsigned len)
{
    if (XIic_DynSend(base, BNO055_I2C_ADDR, &reg, 1, XIIC_REPEATED_START) != 1)
        return 0;
    return XIic_DynRecv(base, BNO055_I2C_ADDR, buf, len) == len;
}

static int bno_write(UINTPTR base, uint8_t reg, uint8_t val)
{
    uint8_t msg[2] = { reg, val };
    return XIic_DynSend(base, BNO055_I2C_ADDR, msg, 2, XIIC_STOP) == 2;
}

// Ensure the chip is in NDOF. Mode changes must route through CONFIG; a chip
// already in NDOF (a previous read, or a warm host reconnect) is left alone so
// the fusion filter keeps its state and calibration.
static int bno_ensure_ndof(UINTPTR base, uint8_t *mode_out)
{
    uint8_t mode = 0;
    if (!bno_read(base, BNO055_REG_OPR_MODE, &mode, 1))
        return 0;
    mode &= 0x0F;
    if (mode == BNO055_MODE_NDOF) {
        *mode_out = mode;
        return 1;
    }
    if (mode != BNO055_MODE_CONFIG) {
        if (!bno_write(base, BNO055_REG_OPR_MODE, BNO055_MODE_CONFIG))
            return 0;
        usleep(BNO055_TO_CONFIG_MS * 1000);
    }
    if (!bno_write(base, BNO055_REG_OPR_MODE, BNO055_MODE_NDOF))
        return 0;
    usleep(BNO055_FROM_CONFIG_MS * 1000);
    if (!bno_read(base, BNO055_REG_OPR_MODE, &mode, 1))
        return 0;
    *mode_out = mode & 0x0F;
    return (mode & 0x0F) == BNO055_MODE_NDOF;
}

static int16_t le16(const uint8_t *p) { return (int16_t)(p[0] | (p[1] << 8)); }

int pl_imu_read_sample(int port, imu_sample_response_t *out)
{
    UINTPTR base = port ? IMUDET_B_BASE : IMUDET_A_BASE;
    uint8_t raw[32];   // one burst 0x08..0x27: acc, mag, gyr, euler, quat
    uint8_t mode = 0;

    out->status = 0;
    out->version = IMUREAD_VERSION;

    XIic_DynInit(base);
    out->status |= (uint32_t)(XIic_ReadReg(base, XIIC_SR_REG_OFFSET) & 0xFF)
                   << IMUREAD_R_SR_SHIFT;

    if (!bno_ensure_ndof(base, &mode)) {
        // Distinguish "no device" from "device but mode change failed":
        // retry the bare mode read -- an ACK here means the chip is present.
        out->status |= bno_read(base, BNO055_REG_OPR_MODE, &mode, 1)
                       ? IMUREAD_R_MODEFAIL : IMUREAD_R_NOACK;
        out->status |= (uint32_t)mode << IMUREAD_R_MODE_SHIFT;
        return 0;
    }
    out->status |= (uint32_t)mode << IMUREAD_R_MODE_SHIFT;

    // Everything from accel through quaternion in one burst (the BNO055
    // auto-increments); slicing one transaction beats three address cycles.
    if (!bno_read(base, BNO055_REG_ACC_DATA, raw, sizeof(raw))) {
        out->status |= IMUREAD_R_NOACK;
        return 0;
    }
    out->acc_x  = le16(raw + 0);  out->acc_y  = le16(raw + 2);  out->acc_z  = le16(raw + 4);
    out->gyr_x  = le16(raw + 12); out->gyr_y  = le16(raw + 14); out->gyr_z  = le16(raw + 16);
    out->quat_w = le16(raw + 24); out->quat_x = le16(raw + 26);
    out->quat_y = le16(raw + 28); out->quat_z = le16(raw + 30);

    uint8_t tail[2];  // 0x34 temp, 0x35 calib_stat
    if (bno_read(base, BNO055_REG_TEMP, tail, 2)) {
        out->temp_c = (int8_t)tail[0];
        out->calib_stat = tail[1];
    } else {
        out->temp_c = 0;
        out->calib_stat = 0;
    }
    out->reserved = 0;
    out->status |= IMUREAD_R_OK;
    return 1;
}

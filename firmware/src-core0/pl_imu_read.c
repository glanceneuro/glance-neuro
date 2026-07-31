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

// Register-pointer write with repeated start, then an n-byte read.
//
// DELIBERATELY NOT XIic_DynSend / XIic_DynRecv. Those spin on BUS_BUSY with no
// timeout (xiic_l.c: `while ((StatusRegister & XIIC_SR_BUS_BUSY_MASK) != ...)`),
// so a bus that never comes ready wedges whichever core called them -- and this
// path runs from a TCP command handler on core 0, where that is a hung board and
// a watchdog reset, not a failed command. A fabric swap floats these pins for
// tens of milliseconds, which is exactly a bus that is briefly not ready.
//
// The sequence on the wire is identical to the vendor's, and identical to what
// pl_i2c_probe.c uses -- proven on hardware by i2c_scan and eeprom_read. Only
// the waits are bounded.
#define BNO_XFER_TIMEOUT_US 20000

static int bno_wait_busy(UINTPTR base)
{
    for (int us = 0; us < BNO_XFER_TIMEOUT_US; us += 10) {
        if (XIic_ReadIisr(base) & (XIIC_INTR_TX_ERROR_MASK | XIIC_INTR_ARB_LOST_MASK))
            return 0;
        if (XIic_ReadReg(base, XIIC_SR_REG_OFFSET) & XIIC_SR_BUS_BUSY_MASK)
            return 1;
        usleep(10);
    }
    return 0;
}

int pl_imu_bno_read(UINTPTR base, uint8_t reg, uint8_t *buf, unsigned len)
{
    XIic_ClearIisr(base, XIIC_INTR_TX_ERROR_MASK | XIIC_INTR_ARB_LOST_MASK);
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | (BNO055_I2C_ADDR << 1));
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET, reg);
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | (BNO055_I2C_ADDR << 1) | 1);
    if (!bno_wait_busy(base)) { XIic_DynInit(base); return 0; }
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET, XIIC_TX_DYN_STOP_MASK | len);

    // Data first, errors after: the core NACKs the final byte to end a master
    // receive, so TX_ERROR latches on a read that succeeded.
    unsigned got = 0;
    for (int us = 0; us < BNO_XFER_TIMEOUT_US; us += 10) {
        while (got < len &&
               !(XIic_ReadReg(base, XIIC_SR_REG_OFFSET) & XIIC_SR_RX_FIFO_EMPTY_MASK))
            buf[got++] = (uint8_t)XIic_ReadReg(base, XIIC_DRR_REG_OFFSET);
        if (got == len) return 1;
        uint32_t iisr = XIic_ReadIisr(base);
        if ((iisr & XIIC_INTR_ARB_LOST_MASK) ||
            ((iisr & XIIC_INTR_TX_ERROR_MASK) && (len - got) > 1))
            break;
        usleep(10);
    }
    XIic_DynInit(base);
    return 0;
}

static int bno_write(UINTPTR base, uint8_t reg, uint8_t val)
{
    XIic_ClearIisr(base, XIIC_INTR_TX_ERROR_MASK | XIIC_INTR_ARB_LOST_MASK);
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | (BNO055_I2C_ADDR << 1));
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET, reg);
    // Dynamic write: the stop bit rides on the last data byte (no count word).
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET, XIIC_TX_DYN_STOP_MASK | val);

    for (int us = 0; us < BNO_XFER_TIMEOUT_US; us += 10) {
        uint32_t iisr = XIic_ReadIisr(base);
        if (iisr & (XIIC_INTR_TX_ERROR_MASK | XIIC_INTR_ARB_LOST_MASK)) {
            XIic_DynInit(base);
            return 0;                       // NACK -- nothing at this address
        }
        uint32_t sr = XIic_ReadReg(base, XIIC_SR_REG_OFFSET);
        if ((sr & XIIC_SR_TX_FIFO_EMPTY_MASK) && !(sr & XIIC_SR_BUS_BUSY_MASK) && us >= 300)
            return 1;                       // drained and the bus is released
        usleep(10);
    }
    XIic_DynInit(base);
    return 0;
}

// Ensure the chip is in NDOF. Mode changes must route through CONFIG; a chip
// already in NDOF (a previous read, or a warm host reconnect) is left alone so
// the fusion filter keeps its state and calibration. Exported: the continuous
// stream (pl_imu_stream.c) does the same blocking entry once at imu_start.
int pl_imu_ndof_enter(UINTPTR base, uint8_t *mode_out)
{
    uint8_t mode = 0;
    if (!pl_imu_bno_read(base, BNO055_REG_OPR_MODE, &mode, 1))
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
    if (!pl_imu_bno_read(base, BNO055_REG_OPR_MODE, &mode, 1))
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

    if (!pl_imu_ndof_enter(base, &mode)) {
        // Distinguish "no device" from "device but mode change failed":
        // retry the bare mode read -- an ACK here means the chip is present.
        out->status |= pl_imu_bno_read(base, BNO055_REG_OPR_MODE, &mode, 1)
                       ? IMUREAD_R_MODEFAIL : IMUREAD_R_NOACK;
        out->status |= (uint32_t)mode << IMUREAD_R_MODE_SHIFT;
        return 0;
    }
    out->status |= (uint32_t)mode << IMUREAD_R_MODE_SHIFT;

    // Everything from accel through quaternion in one burst (the BNO055
    // auto-increments); slicing one transaction beats three address cycles.
    if (!pl_imu_bno_read(base, BNO055_REG_ACC_DATA, raw, sizeof(raw))) {
        out->status |= IMUREAD_R_NOACK;
        return 0;
    }
    out->acc_x  = le16(raw + 0);  out->acc_y  = le16(raw + 2);  out->acc_z  = le16(raw + 4);
    out->gyr_x  = le16(raw + 12); out->gyr_y  = le16(raw + 14); out->gyr_z  = le16(raw + 16);
    out->quat_w = le16(raw + 24); out->quat_x = le16(raw + 26);
    out->quat_y = le16(raw + 28); out->quat_z = le16(raw + 30);

    uint8_t tail[2];  // 0x34 temp, 0x35 calib_stat
    if (pl_imu_bno_read(base, BNO055_REG_TEMP, tail, 2)) {
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

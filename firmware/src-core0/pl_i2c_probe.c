// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University

#include "pl_i2c_probe.h"
#include "pl_imu_detect.h"   // IMUDET_*_BASE
#include "xiic_l.h"
#include "sleep.h"

// One address probe = the shortest legal write: START+addr, one 0x00 data
// byte, STOP. For every 24xx (sets the read pointer low byte) and the BNO055
// (sets the register pointer) this is a no-op write -- non-destructive by
// construction. The blocking XIic_DynSend is NOT used: on a bus that is
// actually an LVDS lane it can spin forever, and this firmware has already
// paid once for an unbounded wait (the absent-slave hang) -- everything here
// runs against a deadline.
//
// Returns 1 with *ack set on a decided probe, 0 on deadline (bus wedged).
static int probe_addr(UINTPTR base, uint8_t addr7, int *ack)
{
    XIic_DynInit(base);
    XIic_ClearIisr(base, XIIC_INTR_TX_ERROR_MASK | XIIC_INTR_ARB_LOST_MASK);
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | ((uint32_t)addr7 << 1));
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET, XIIC_TX_DYN_STOP_MASK | 0x00);

    int seen_busy = 0;
    for (int us = 0; us < 5000; us += 10) {
        uint32_t iisr = XIic_ReadIisr(base);
        if (iisr & (XIIC_INTR_TX_ERROR_MASK | XIIC_INTR_ARB_LOST_MASK)) {
            *ack = 0;
            return 1;                        // NACK -- decided, bus fine
        }
        uint32_t sr = XIic_ReadReg(base, XIIC_SR_REG_OFFSET);
        if (sr & XIIC_SR_BUS_BUSY_MASK) {
            seen_busy = 1;
        } else if ((sr & XIIC_SR_TX_FIFO_EMPTY_MASK) &&
                   (seen_busy || us >= 300)) {
            // FIFO drained, bus idle again (or never went busy in 300 us --
            // at 100 kHz the START must appear within ~100 us, so an idle
            // bus with an empty FIFO and no error means the write completed
            // between polls). No TX_ERROR latched -> the address was ACKed.
            *ack = 1;
            return 1;
        }
        usleep(10);
    }
    XIic_DynInit(base);                      // abort whatever is stuck
    return 0;
}

void pl_i2c_scan(int port, i2c_scan_response_t *out)
{
    UINTPTR base = port ? IMUDET_B_BASE : IMUDET_A_BASE;
    out->status = 0;
    out->version = I2C_SCAN_VERSION;
    for (int i = 0; i < 16; i++) out->bitmap[i] = 0;

    for (uint8_t a = I2C_SCAN_FIRST; a <= I2C_SCAN_LAST; a++) {
        int ack = 0;
        if (!probe_addr(base, a, &ack)) {
            // Wedged: report where and stop -- 100+ more deadlines on a dead
            // bus would stall the command loop for half a second to no end.
            out->status = 1u | ((uint32_t)a << 8);
            return;
        }
        if (ack)
            out->bitmap[a >> 3] |= (uint8_t)(1u << (a & 7));
    }
}

void pl_i2c_read(int port, uint8_t i2c_addr, int addr_width, uint16_t offset,
                 uint8_t nbytes, eeprom_read_response_t *out)
{
    UINTPTR base = port ? IMUDET_B_BASE : IMUDET_A_BASE;
    out->status = 0;
    out->nbytes = 0;
    out->version = EEPROM_READ_VERSION;
    for (int i = 0; i < EEPROM_READ_MAX; i++) out->data[i] = 0;
    if (nbytes > EEPROM_READ_MAX) nbytes = EEPROM_READ_MAX;
    if (nbytes == 0) return;

    // Combined write-then-read, same preloaded shape the IMU stream uses --
    // offset write (1 or 2 big-endian bytes), repeated START, n-byte read.
    XIic_DynInit(base);
    XIic_ClearIisr(base, XIIC_INTR_TX_ERROR_MASK | XIIC_INTR_ARB_LOST_MASK);
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | ((uint32_t)i2c_addr << 1));
    if (addr_width == 2)
        XIic_WriteReg(base, XIIC_DTR_REG_OFFSET, (offset >> 8) & 0xFF);
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET, offset & 0xFF);
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | ((uint32_t)i2c_addr << 1) | 1);
    XIic_WriteReg(base, XIIC_DTR_REG_OFFSET, XIIC_TX_DYN_STOP_MASK | nbytes);

    // 32 bytes at 100 kHz is ~3.2 ms on the wire; 20 ms of deadline covers
    // clock stretching with room to spare.
    for (int us = 0; us < 20000; us += 10) {
        uint32_t iisr = XIic_ReadIisr(base);
        if (iisr & (XIIC_INTR_TX_ERROR_MASK | XIIC_INTR_ARB_LOST_MASK)) {
            XIic_DynInit(base);
            out->status = 1;                 // NACK (no device / bad offset width)
            return;
        }
        while (out->nbytes < nbytes &&
               !(XIic_ReadReg(base, XIIC_SR_REG_OFFSET) & XIIC_SR_RX_FIFO_EMPTY_MASK)) {
            out->data[out->nbytes++] =
                (uint8_t)XIic_ReadReg(base, XIIC_DRR_REG_OFFSET);
        }
        if (out->nbytes == nbytes) return;   // status 0: complete
        usleep(10);
    }
    XIic_DynInit(base);
    out->status = out->nbytes ? (3u | ((uint32_t)out->nbytes << 8)
                                     | ((uint32_t)nbytes << 16))
                              : 2u;
}

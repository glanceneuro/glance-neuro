// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Host-test environment for pl_imu_stream.c (compiled with -DIMU_HOST_TEST):
// a register-accurate simulation of the AXI IIC dynamic mode plus a BNO055
// behavior model, faithful to PG090 for the subset the stream uses --
// combined write-then-read command FIFO, RX FIFO with SR empty flag, NACK ->
// IISR TX_ERROR, and transfer time that advances with the mock clock. All
// constants mirror xiic_l.h verbatim so the state machine code is identical
// on target and host.
#ifndef IMU_HOST_MOCK_H
#define IMU_HOST_MOCK_H

#include <stdint.h>
#include <stddef.h>
#include "xil_types.h"

// --- xiic_l.h subset (values verbatim) --------------------------------------
#define XIIC_IISR_OFFSET            0x20
#define XIIC_RESETR_OFFSET          0x40
#define XIIC_CR_REG_OFFSET          0x100
#define XIIC_SR_REG_OFFSET          0x104
#define XIIC_DTR_REG_OFFSET         0x108
#define XIIC_DRR_REG_OFFSET         0x10C
#define XIIC_RFO_REG_OFFSET         0x118
#define XIIC_RFD_REG_OFFSET         0x120
#define XIIC_INTR_ARB_LOST_MASK     0x00000001
#define XIIC_INTR_TX_ERROR_MASK     0x00000002
#define XIIC_SR_BUS_BUSY_MASK       0x00000004
#define XIIC_SR_RX_FIFO_EMPTY_MASK  0x00000040
#define XIIC_TX_DYN_START_MASK      0x00000100
#define XIIC_TX_DYN_STOP_MASK       0x00000200
#define XIIC_RESET_MASK             0x0000000A

uint32_t mock_iic_read(UINTPTR base, uint32_t offset);
void     mock_iic_write(UINTPTR base, uint32_t offset, uint32_t value);
int      mock_dyninit(UINTPTR base);

#define XIic_ReadReg(base, off)         mock_iic_read((base), (off))
#define XIic_WriteReg(base, off, val)   mock_iic_write((base), (off), (val))
#define XIic_ReadIisr(base)             mock_iic_read((base), XIIC_IISR_OFFSET)
// Real macro semantics: writing 1s to set IISR bits clears them.
#define XIic_ClearIisr(base, mask) \
    mock_iic_write((base), XIIC_IISR_OFFSET, \
                   mock_iic_read((base), XIIC_IISR_OFFSET) & (mask))
#define XIic_DynInit(base)              mock_dyninit(base)

// --- xiltimer.h subset ------------------------------------------------------
typedef uint64_t XTime;
#define COUNTS_PER_SECOND 1000000ull        // mock clock: 1 tick = 1 us
void XTime_GetTime(XTime *t);

// --- lwip subset ------------------------------------------------------------
typedef int err_t;
#define ERR_OK   0
#define ERR_MEM (-1)
#define PBUF_TRANSPORT 0
#define PBUF_REF       1
struct pbuf { void *payload; };
struct udp_pcb { int dummy; };
typedef struct { uint32_t addr; } ip_addr_t;
struct pbuf *pbuf_alloc(int layer, uint16_t len, int type);
void pbuf_free(struct pbuf *p);
struct udp_pcb *udp_new(void);
err_t udp_sendto(struct udp_pcb *pcb, struct pbuf *p,
                 const ip_addr_t *dst, uint16_t port);

// --- firmware globals / helpers the stream uses -----------------------------
extern uint32_t udp_dest_ip;
extern uint16_t udp_dest_port;
extern volatile int pl_has_iic_a, pl_has_iic_b;
uint64_t pl_get_timestamp(void);
void send_message(const char *fmt, ...);
int pl_imu_ndof_enter(UINTPTR base, uint8_t *mode_out);   // mock-controlled

// Real firmware headers (they only need stdint / the stub xil_types.h).
#include "pl_imu_detect.h"     // IMUDET_*_BASE, BNO055_I2C_ADDR
#include "pl_imu_stream.h"
#define UNIFIED_MAGIC   0xCAFEBABE
#define UNIFIED_VERSION 1
// BNO055 register constants, mirrored from pl_imu_read.h. That header CAN be
// included here (the stub xil_types.h supplies UINTPTR) -- what collides is the
// mock's own stand-in definition of pl_imu_ndof_enter, which is a link-time
// clash the probe binary resolves with IMU_PROBE_TEST.
#define BNO055_REG_ACC_DATA   0x08
#define BNO055_REG_GYR_DATA   0x14
#define BNO055_REG_QUA_DATA   0x20
#define BNO055_REG_TEMP       0x34
#define BNO055_REG_CALIB_STAT 0x35
#define BNO055_REG_OPR_MODE   0x3D
#define BNO055_MODE_NDOF      0x0C

// --- test control surface ---------------------------------------------------
// The simulated BNO055 on each port (0 = A at IMUDET_A_BASE, 1 = B).
typedef struct {
    int     present;            // 0 -> every transaction NACKs (TX_ERROR)
    int     wedge;              // 1 -> accept commands but never return data
    int     never_busy;         // 1 -> the bus never asserts BUS_BUSY (dead line)
    int16_t quat[4], acc[3], gyr[3];
    int8_t  temp;
    uint8_t calib;
    uint8_t regs_read;          // count of completed read transactions
} mock_bno_t;

// Which 7-bit addresses ACK an address-only probe (used by the i2c_scan tests).
extern uint8_t mock_i2c_present[128];

typedef struct {
    uint8_t  data[2048];
    uint16_t len;
} mock_pkt_t;

extern mock_bno_t   mock_bno[2];
extern mock_pkt_t   mock_pkts[512];     // every packet udp_sendto delivered
extern int          mock_n_pkts;
extern int          mock_pbuf_fail;     // force pbuf_alloc to fail
extern int          mock_ndof_fail[2];  // force pl_imu_ndof_enter failure
extern int          mock_ndof_calls[2];
extern int          mock_dyninit_calls[2];
extern uint32_t     mock_timestamp_hi, mock_timestamp_lo;
extern uint32_t     mock_xfer_us;       // simulated bus time per transaction
extern int          mock_bad_sequence;   // FIFO writes deviating from the combined sequence
// Every word written to the TX command FIFO, in order. Lets a test assert the
// EXACT bus traffic -- e.g. that an address probe emits one word and no data
// byte -- rather than inferring it from an ACK.
#define MOCK_DTR_LOG_MAX 256
extern uint32_t     mock_dtr_log[MOCK_DTR_LOG_MAX];
extern int          mock_dtr_n;

void mock_reset(void);                  // fresh state for each test
void mock_advance_us(uint64_t us);      // move the mock clock forward

#endif // IMU_HOST_MOCK_H

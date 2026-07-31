// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Simulation backend for imu_host_mock.h. Models what the stream relies on:
//   - the dynamic-mode command FIFO parsing a combined write-then-read
//     (START+addrW, reg, START+addrR, STOP+count)
//   - transfer time: results appear only after mock_xfer_us of mock clock
//   - an absent device NACKing (IISR TX_ERROR after the address goes out)
//   - a wedged bus (command accepted, data never arrives)
//   - the RX FIFO with its SR empty flag
// A parse that deviates from that exact command sequence increments
// mock_bad_sequence -- the tests assert it stays 0, which pins the FIFO
// traffic to be byte-identical with what the blocking XIic_Dyn* pair emits.

#include "imu_host_mock.h"
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>

mock_bno_t mock_bno[2];
mock_pkt_t mock_pkts[512];
int        mock_n_pkts;
int        mock_pbuf_fail;
int        mock_ndof_fail[2];
int        mock_ndof_calls[2];
int        mock_dyninit_calls[2];
uint32_t   mock_timestamp_hi, mock_timestamp_lo;
uint32_t   mock_xfer_us = 900;      // ~8 data bytes + addressing at 100 kHz
int        mock_bad_sequence;

static uint64_t mock_now;

uint32_t udp_dest_ip   = 0xC0A81264;
uint16_t udp_dest_port = 0x6800;
volatile int pl_has_iic_a = 1, pl_has_iic_b = 1;

typedef struct {
    uint8_t  rx[16];
    int      rx_r, rx_n;
    uint32_t iisr;
    int      st;            // combined-command parse: 0 idle .. 3 await STOP
    int      addr_phase_busy; // addresses queued; core will take the bus
    uint64_t busy_at;       // when BUS_BUSY actually asserts (START takes wire time)
    uint8_t  cur_reg;
    int      pending;       // 0 none, 1 data due, 2 NACK due
    uint64_t due_at;
    uint8_t  pend_reg, pend_len;
} sim_iic_t;

static sim_iic_t sim[2];

static int port_of(UINTPTR base) { return base == IMUDET_A_BASE ? 0 : 1; }

// BUS_BUSY does not assert the instant software writes the FIFO: the core has
// to drive a START and the address onto the wire first (tens of microseconds
// at 100 kHz). Modelling that delay is what makes "write the count only once
// the bus is busy" a testable property instead of a no-op.
#define MOCK_START_LATENCY_US 60

static int sim_bus_busy(const sim_iic_t *s)
{
    if (s->pending) return 1;
    return s->addr_phase_busy && mock_now >= s->busy_at;
}

// The BNO055 register image the simulated bursts read from.
static uint8_t bno_reg_byte(int port, uint8_t addr)
{
    mock_bno_t *b = &mock_bno[port];
    if (addr >= 0x08 && addr <= 0x0D)
        return (uint8_t)(b->acc[(addr - 0x08) / 2] >> ((addr & 1) ? 8 : 0));
    if (addr >= 0x14 && addr <= 0x19)
        return (uint8_t)(b->gyr[(addr - 0x14) / 2] >> ((addr & 1) ? 8 : 0));
    if (addr >= 0x20 && addr <= 0x27)
        return (uint8_t)(b->quat[(addr - 0x20) / 2] >> ((addr & 1) ? 8 : 0));
    if (addr == BNO055_REG_TEMP)       return (uint8_t)b->temp;
    if (addr == BNO055_REG_CALIB_STAT) return b->calib;
    if (addr == BNO055_REG_OPR_MODE)   return BNO055_MODE_NDOF;
    return 0;
}

static void sim_update(int port)
{
    sim_iic_t *s = &sim[port];
    if (!s->pending || mock_now < s->due_at) return;
    if (s->pending == 2) {
        s->iisr |= XIIC_INTR_TX_ERROR_MASK;
    } else {
        for (int i = 0; i < s->pend_len && s->rx_n < 16; i++)
            s->rx[(s->rx_r + s->rx_n++) % 16] =
                bno_reg_byte(port, (uint8_t)(s->pend_reg + i));
        mock_bno[port].regs_read++;
    }
    s->pending = 0;
}

uint32_t mock_iic_read(UINTPTR base, uint32_t offset)
{
    sim_iic_t *s = &sim[port_of(base)];
    sim_update(port_of(base));
    switch (offset) {
    case XIIC_SR_REG_OFFSET: {
        uint32_t v = 0xC0 & ~XIIC_SR_RX_FIFO_EMPTY_MASK;   // FIFOs "live"
        if (s->rx_n == 0) v |= XIIC_SR_RX_FIFO_EMPTY_MASK;
        // Busy while the address phase is on the wire awaiting a count, and
        // while a transfer is actually running. An ABSENT device NACKs its
        // address, so the core never takes the bus -- modelled by leaving
        // addr_phase_busy clear for it (below).
        if (sim_bus_busy(s)) v |= XIIC_SR_BUS_BUSY_MASK;
        return v;
    }
    case XIIC_DRR_REG_OFFSET: {
        if (s->rx_n == 0) return 0xEE;                     // underflow canary
        uint8_t v = s->rx[s->rx_r];
        s->rx_r = (s->rx_r + 1) % 16; s->rx_n--;
        return v;
    }
    case XIIC_RFO_REG_OFFSET:  return s->rx_n ? (uint32_t)(s->rx_n - 1) : 0;
    case XIIC_IISR_OFFSET:     return s->iisr;
    default:                   return 0;
    }
}

void mock_iic_write(UINTPTR base, uint32_t offset, uint32_t value)
{
    int port = port_of(base);
    sim_iic_t *s = &sim[port];

    if (offset == XIIC_IISR_OFFSET) { s->iisr &= ~value; return; }
    if (offset == XIIC_RESETR_OFFSET) {
        memset(s, 0, sizeof(*s));
        return;
    }
    if (offset != XIIC_DTR_REG_OFFSET) return;

    // Dynamic command FIFO parse -- must be exactly the combined sequence.
    uint32_t addr_w = XIIC_TX_DYN_START_MASK | (BNO055_I2C_ADDR << 1);
    switch (s->st) {
    case 0:
        if (value == addr_w) {
            s->st = 1;
            if (!mock_bno[port].present) {
                // Real hardware NACKs the very first address and releases the
                // bus, so TX_ERROR latches without the core ever going busy --
                // the firmware must notice that instead of waiting out its
                // transfer deadline.
                s->pending = 2;
                s->due_at  = mock_now + 200;
            }
        } else {
            mock_bad_sequence++;
        }
        break;
    case 1:
        if (value <= 0xFF) { s->cur_reg = (uint8_t)value; s->st = 2; }
        else mock_bad_sequence++;
        break;
    case 2:
        if (value == (addr_w | 1)) {
            s->st = 3;
            // The core takes the bus on the address phase and clock-stretches
            // waiting for the byte count -- so BUS_BUSY reads set from here.
            // A device that never ACKed leaves the bus alone.
            if (mock_bno[port].present) {
                s->addr_phase_busy = 1;
                s->busy_at = mock_now + MOCK_START_LATENCY_US;
            }
        } else {
            mock_bad_sequence++;
        }
        break;
    case 3:
        if (value & XIIC_TX_DYN_STOP_MASK) {
            uint8_t len = value & 0xFF;
            // Enforce the vendor's proven ordering: the count must be written
            // while the bus is ACTUALLY busy, never speculatively before the
            // addresses have reached the wire.
            if (!sim_bus_busy(s)) mock_bad_sequence++;
            s->addr_phase_busy = 0;
            s->st = 0;
            s->pend_reg = s->cur_reg;
            s->pend_len = len;
            if (!mock_bno[port].present) {
                s->pending = 2;                    // NACK (already scheduled)
                s->due_at  = mock_now + 200;
            } else if (mock_bno[port].wedge) {
                s->pending = 0;                    // silently swallowed forever
            } else {
                s->pending = 1;
                s->due_at  = mock_now + mock_xfer_us;
            }
        } else {
            mock_bad_sequence++;
        }
        break;
    }
}

int mock_dyninit(UINTPTR base)
{
    int port = port_of(base);
    mock_dyninit_calls[port]++;
    memset(&sim[port], 0, sizeof(sim[port]));
    return 0;
}

void XTime_GetTime(XTime *t) { *t = mock_now; }
void mock_advance_us(uint64_t us) { mock_now += us; }

// --- lwip ------------------------------------------------------------------
static struct pbuf mock_pbuf;
static uint16_t    mock_pbuf_len;
static int         mock_pbuf_used;

struct pbuf *pbuf_alloc(int layer, uint16_t len, int type)
{
    (void)layer; (void)type;
    if (mock_pbuf_fail) return NULL;
    mock_pbuf_len = len; mock_pbuf_used = 1;
    return &mock_pbuf;
}
void pbuf_free(struct pbuf *p) { (void)p; mock_pbuf_used = 0; }
struct udp_pcb *udp_new(void) { static struct udp_pcb pcb; return &pcb; }

err_t udp_sendto(struct udp_pcb *pcb, struct pbuf *p,
                 const ip_addr_t *dst, uint16_t port)
{
    (void)pcb; (void)dst; (void)port;
    if (mock_n_pkts < (int)(sizeof(mock_pkts) / sizeof(mock_pkts[0]))) {
        mock_pkts[mock_n_pkts].len = mock_pbuf_len;
        memcpy(mock_pkts[mock_n_pkts].data, p->payload, mock_pbuf_len);
        mock_n_pkts++;
    }
    return ERR_OK;
}

// --- firmware glue ----------------------------------------------------------
uint64_t pl_get_timestamp(void)
{
    return ((uint64_t)mock_timestamp_hi << 32) | mock_timestamp_lo;
}

void send_message(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    printf("  [FW] "); vprintf(fmt, ap);
    va_end(ap);
}

int pl_imu_ndof_enter(UINTPTR base, uint8_t *mode_out)
{
    int port = port_of(base);
    mock_ndof_calls[port]++;
    if (mock_ndof_fail[port]) return 0;
    *mode_out = BNO055_MODE_NDOF;
    return 1;
}

void mock_reset(void)
{
    memset(sim, 0, sizeof(sim));
    memset(mock_bno, 0, sizeof(mock_bno));
    memset(mock_ndof_fail, 0, sizeof(mock_ndof_fail));
    memset(mock_ndof_calls, 0, sizeof(mock_ndof_calls));
    memset(mock_dyninit_calls, 0, sizeof(mock_dyninit_calls));
    mock_n_pkts = 0; mock_pbuf_fail = 0; mock_bad_sequence = 0;
    mock_xfer_us = 900;
    mock_timestamp_hi = 0; mock_timestamp_lo = 0;
    mock_bno[0].present = mock_bno[1].present = 1;
    mock_bno[0].calib = mock_bno[1].calib = 0xC3;
    // Distinct, sign-exercising values per port.
    for (int p = 0; p < 2; p++) {
        for (int i = 0; i < 4; i++) mock_bno[p].quat[i] = (int16_t)(0x4000 - i * 1000 - p * 7);
        for (int i = 0; i < 3; i++) mock_bno[p].acc[i]  = (int16_t)(-981 + i * 100 + p * 3);
        for (int i = 0; i < 3; i++) mock_bno[p].gyr[i]  = (int16_t)(160 * (i - 1) + p);
        mock_bno[p].temp = (int8_t)(23 + p);
    }
}

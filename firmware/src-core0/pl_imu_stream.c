// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Continuous BNO055 readout (stream_type = 4). See pl_imu_stream.h for the
// wire format and the API contract; docs/imu-ingestion.md for the design.
//
// The whole point of the shape below: the 30 kHz broadband pump shares this
// loop, so NOTHING here may block. Every I2C transfer is a "combined
// write-then-read" preloaded into the AXI IIC's 16-deep TX command FIFO in one
// go (dynamic mode, PG090): the core then runs the bus on its own -- START,
// register pointer, repeated START, N-byte read, STOP -- while we come back
// once per main-loop pass and drain whatever landed in the RX FIFO. The
// blocking XIic_DynSend/DynRecv pair used by the one-shot paths produces
// byte-identical FIFO traffic; it just waits in between, which we cannot.
//
// IMU_HOST_TEST compiles this file on a build host against a simulated IIC
// core + BNO055 (firmware/test-host/), which is how the state machine's
// logic -- tick cadence, FIFO handling, NACK/timeout recovery, packet
// assembly -- is regression-tested without a board.

#ifdef IMU_HOST_TEST
#include "imu_host_mock.h"
#else
#include "main.h"
#include "shared_print.h"
#include "pl_imu_detect.h"   // IMUDET_*_BASE, BNO055_I2C_ADDR
#include "pl_imu_read.h"     // BNO055 register map + pl_imu_ndof_enter
#include "pl_imu_stream.h"
#include "xiic_l.h"
#include "xiltimer.h"        // XTime_GetTime / COUNTS_PER_SECOND
#include "lwip/udp.h"
#endif

// ---------------------------------------------------------------------------
// Per-tick transfer plan
// ---------------------------------------------------------------------------
// Three bursts per sample tick, each small enough to fit the 16-deep RX FIFO
// with room to spare (the core throttles SCL when the FIFO fills; never let it).
// dst is the byte offset into the 20-byte sample image, whose layout is the
// packet payload verbatim: quat w,x,y,z, acc x,y,z, gyr x,y,z as LE int16.
typedef struct { uint8_t reg, len, dst; } imu_burst_t;
static const imu_burst_t imu_data_bursts[3] = {
    { BNO055_REG_QUA_DATA, 8, 0  },
    { BNO055_REG_ACC_DATA, 6, 8  },
    { BNO055_REG_GYR_DATA, 6, 14 },
};
// A 4th housekeeping burst (temp 0x34 + calib_stat 0x35) rides along every
// IMU_HK_TICKS-th tick: cheap liveness telemetry -- a chip that brownout-reset
// mid-stream shows calib_stat collapsing to 0 while quat freezes.
#define IMU_HK_BURST_REG   BNO055_REG_TEMP
#define IMU_HK_BURST_LEN   2
#define IMU_HK_TICKS       100
#define IMU_N_DATA_BURSTS  3

// Give a burst 20 ms of wall clock before declaring the bus wedged: worst case
// on the wire is ~1 ms (8 data bytes + addressing at 100 kHz) plus BNO055
// clock stretching, so 20x headroom without letting a dead bus linger.
#define IMU_XFER_TIMEOUT_MS   20
// Consecutive failed ticks before a port shuts itself off. Transient bus upsets
// recover on the next tick; a genuinely absent/unpowered IMU should not spam
// an error path 100 times a second forever.
#define IMU_MAX_CONSEC_ERRORS 16

typedef struct {
    uint8_t  running;
    uint8_t  in_flight;      // a burst is loaded in the core's FIFO
    uint8_t  await_count;    // addresses queued; waiting for BUS_BUSY to add the count
    uint8_t  await_idle;     // waiting for the previous burst's STOP to release the bus
    uint8_t  pend_len;       // byte count for the burst in flight
    uint8_t  burst_idx;      // 0..2 data, 3 = housekeeping
    uint8_t  got;            // bytes drained so far for this burst
    uint8_t  hk_due;         // run the housekeeping burst after this tick's data
    uint8_t  sample[20];     // payload image (see imu_data_bursts)
    uint8_t  hk[IMU_HK_BURST_LEN];
    uint8_t  calib_stat;     // 0xFF until the first housekeeping burst lands
    int8_t   temp_c;
    uint8_t  opr_mode;       // read back at NDOF entry
    uint8_t  iic_errors, send_drops, consec_errors;   // first two saturate at 255
    uint16_t tick_count;
    uint32_t seq;
    XTime    next_tick;
    XTime    deadline;
    UINTPTR  base;
} imu_port_t;

static imu_port_t imu_port[2] = {
    { .base = IMUDET_A_BASE }, { .base = IMUDET_B_BASE },
};
static uint32_t imu_period_ms = IMU_PERIOD_MS_DEFAULT;
static struct udp_pcb *imu_pcb;
static XTime imu_last_service;   // 0 = never called (see pl_imu_stream_service)

// Staging ring for the zero-copy send (PBUF_REF): a slot must outlive its TX
// descriptor. 8 slots at 100 Hz means a slot is reused after 80 ms -- orders
// of magnitude past TX drain.
//
// ORDINARY CACHED MEMORY, deliberately, unlike the broadband and LFP staging
// buffers in the non-cacheable pl_dma region. Those hold data written by a PL
// master (the CDMA), so the CPU must never hold a stale cached copy. This
// packet is built by the CPU and read by the GEM, and the lwIP port flushes
// each pbuf payload before handing it to the TX descriptor
// (xemacpsif_dma.c sgsend: Xil_DCacheFlushRange when !IsCacheCoherent, which
// is the Zynq-7000 case), so the flush is already covered. The 64-byte slot
// stride keeps every slot on its own cache lines, so that flush can never
// touch a neighbouring slot still pending in the TX ring.
#define IMU_N_SLOTS 8u
static uint32_t imu_staging[IMU_N_SLOTS][16] __attribute__((aligned(64)));
static uint32_t imu_slot;

uint32_t imu_stream_pkts_sent;   // get_status visibility (mirrors lfp_udp_packets_sent)

static XTime imu_ms_to_ticks(uint32_t ms)
{
    return (XTime)((COUNTS_PER_SECOND / 1000u) * (uint64_t)ms);
}

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

// Queue the address phase of a combined write-then-read into the TX command
// FIFO: START+addr(W), register pointer, repeated START+addr(R). The byte
// count is NOT written here -- see imu_arm_count().
static void imu_kick(imu_port_t *p, uint8_t reg, uint8_t len)
{
    XIic_ClearIisr(p->base, XIIC_INTR_TX_ERROR_MASK | XIIC_INTR_ARB_LOST_MASK);
    XIic_WriteReg(p->base, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | (BNO055_I2C_ADDR << 1));
    XIic_WriteReg(p->base, XIIC_DTR_REG_OFFSET, reg);
    XIic_WriteReg(p->base, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | (BNO055_I2C_ADDR << 1) | 1);
    p->in_flight = 1;
    p->await_count = 1;
    p->pend_len = len;
    p->got = 0;
    XTime now; XTime_GetTime(&now);
    p->deadline = now + imu_ms_to_ticks(IMU_XFER_TIMEOUT_MS);
}

// Write the dynamic STOP + byte count, but only once the core has actually
// taken the bus. This is the ordering the vendor's blocking XIic_DynRecv uses
// (address, wait for BUS_BUSY, then the count) and the one proven on this
// board by the detect path -- reproduced here without the blocking wait, which
// the 30 kHz pump could never afford. The core clock-stretches while it waits
// for the count, so the bus stays busy until we supply it; a bus that never
// goes busy is a dead bus and the caller's deadline collects it.
static void imu_arm_count(imu_port_t *p)
{
    XIic_WriteReg(p->base, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_STOP_MASK | p->pend_len);
    p->await_count = 0;
}

// Abort whatever is on the bus, reset the core, and skip to the next tick.
// DynInit is the same soft-reset+re-enable the probe paths use -- it leaves
// the core idle and the bus released regardless of where the transfer died.
static void imu_error(imu_port_t *p, int port)
{
    XIic_DynInit(p->base);
    if (p->iic_errors != 0xFF) p->iic_errors++;
    p->in_flight = 0;
    p->await_count = 0;
    p->await_idle = 0;
    p->burst_idx = 0;
    XTime now; XTime_GetTime(&now);
    p->next_tick = now + imu_ms_to_ticks(imu_period_ms);
    if (++p->consec_errors >= IMU_MAX_CONSEC_ERRORS) {
        p->running = 0;
        send_message("IMU stream port %c: stopped after %d consecutive I2C "
                     "errors (IMU unplugged?)\r\n", port ? 'B' : 'A',
                     IMU_MAX_CONSEC_ERRORS);
    }
}

static void imu_publish(imu_port_t *p, int port)
{
    uint32_t *w = imu_staging[imu_slot];
    imu_slot = (imu_slot + 1u) % IMU_N_SLOTS;

    uint64_t ts = pl_get_timestamp();
    w[0] = UNIFIED_MAGIC;
    w[1] = (uint32_t)STREAM_TYPE_IMU | ((uint32_t)UNIFIED_VERSION << 8)
         | ((uint32_t)(port & 1) << 16);
    w[2] = (uint32_t)ts;
    w[3] = (uint32_t)(ts >> 32);
    w[4] = p->seq++;
    w[5] = (imu_period_ms & 0xFFFFu)
         | ((uint32_t)p->iic_errors << 16) | ((uint32_t)p->send_drops << 24);
    w[6] = (uint32_t)p->calib_stat | ((uint32_t)p->opr_mode << 8)
         | ((uint32_t)(uint8_t)p->temp_c << 16);
    w[7] = 0;
    // Payload image is already wire-layout; copy as 5 words.
    const uint32_t *s = (const uint32_t *)(const void *)p->sample;
    for (int i = 0; i < IMU_PKT_PAYLOAD_WORDS; i++) w[8 + i] = s[i];

    // LFP send policy, minus the retry: a stale IMU sample is worth less than
    // the fresh one 10 ms out, so a failed send is a counted drop (and a SEQ
    // gap the host can prove), never a retry that could back up this loop.
    struct pbuf *pb = pbuf_alloc(PBUF_TRANSPORT, IMU_PKT_WORDS * 4, PBUF_REF);
    if (pb == NULL) {
        if (p->send_drops != 0xFF) p->send_drops++;
        return;
    }
    pb->payload = (void *)w;
    ip_addr_t dst; dst.addr = udp_dest_ip;
    err_t e = udp_sendto(imu_pcb, pb, &dst, udp_dest_port);
    pbuf_free(pb);
    if (e != ERR_OK) {
        if (p->send_drops != 0xFF) p->send_drops++;
    } else {
        imu_stream_pkts_sent++;
    }
}

// Close out a tick and schedule the next. Catch-up rule: if servicing fell a
// whole period behind (long PCAP swap, console flood), realign to now rather
// than burst-firing stale ticks back to back.
static void imu_finish_tick(imu_port_t *p)
{
    p->burst_idx = 0;
    p->consec_errors = 0;
    p->tick_count++;
    p->hk_due = (p->tick_count % IMU_HK_TICKS) == 0;
    XTime now; XTime_GetTime(&now);
    p->next_tick += imu_ms_to_ticks(imu_period_ms);
    if (p->next_tick < now)
        p->next_tick = now + imu_ms_to_ticks(imu_period_ms);
}

static void imu_service_port(imu_port_t *p, int port)
{
    if (!p->running) return;

    if (!p->in_flight) {
        XTime now; XTime_GetTime(&now);
        if (p->burst_idx == 0 && now < p->next_tick) return;

        // The previous burst's STOP takes wire time to release the bus, and
        // this loop comes back around in microseconds. Kick while that is
        // still draining and the next BUS_BUSY we observe could be the OLD
        // transaction's -- which would hand the byte count over before this
        // burst's addresses ever reached the wire. So require a genuinely idle
        // bus first, bounded by the same transfer deadline.
        if (XIic_ReadReg(p->base, XIIC_SR_REG_OFFSET) & XIIC_SR_BUS_BUSY_MASK) {
            if (!p->await_idle) {
                p->await_idle = 1;
                p->deadline = now + imu_ms_to_ticks(IMU_XFER_TIMEOUT_MS);
            } else if (now > p->deadline) {
                imu_error(p, port);
            }
            return;
        }
        p->await_idle = 0;

        if (p->burst_idx < IMU_N_DATA_BURSTS) {
            const imu_burst_t *b = &imu_data_bursts[p->burst_idx];
            imu_kick(p, b->reg, b->len);
        } else {
            imu_kick(p, IMU_HK_BURST_REG, IMU_HK_BURST_LEN);
        }
        return;
    }

    // A burst is in flight. One interrupt-status read decides error/no-error;
    // one status read gates the drain. NACK (TX_ERROR) and lost arbitration
    // both mean this transfer is gone -- reset and resync at the next tick.
    uint32_t iisr = XIic_ReadIisr(p->base);
    if (iisr & (XIIC_INTR_TX_ERROR_MASK | XIIC_INTR_ARB_LOST_MASK)) {
        imu_error(p, port);
        return;
    }

    // Address phase queued but the count not yet supplied: hand it over as
    // soon as the core has the bus (see imu_arm_count).
    if (p->await_count) {
        if (XIic_ReadReg(p->base, XIIC_SR_REG_OFFSET) & XIIC_SR_BUS_BUSY_MASK) {
            imu_arm_count(p);
        } else {
            XTime now; XTime_GetTime(&now);
            if (now > p->deadline) imu_error(p, port);
        }
        return;
    }

    uint8_t want = (p->burst_idx < IMU_N_DATA_BURSTS)
                     ? imu_data_bursts[p->burst_idx].len : IMU_HK_BURST_LEN;
    uint8_t *dst = (p->burst_idx < IMU_N_DATA_BURSTS)
                     ? p->sample + imu_data_bursts[p->burst_idx].dst : p->hk;

    while (p->got < want &&
           !(XIic_ReadReg(p->base, XIIC_SR_REG_OFFSET) & XIIC_SR_RX_FIFO_EMPTY_MASK)) {
        dst[p->got++] = (uint8_t)XIic_ReadReg(p->base, XIIC_DRR_REG_OFFSET);
    }

    if (p->got < want) {
        XTime now; XTime_GetTime(&now);
        if (now > p->deadline) imu_error(p, port);
        return;
    }

    // Burst complete.
    p->in_flight = 0;
    p->burst_idx++;
    if (p->burst_idx == IMU_N_DATA_BURSTS) {
        imu_publish(p, port);                 // sample is whole -- ship it now
        if (!p->hk_due) imu_finish_tick(p);   // else: housekeeping burst next pass
    } else if (p->burst_idx > IMU_N_DATA_BURSTS) {
        p->temp_c = (int8_t)p->hk[0];
        p->calib_stat = p->hk[1];
        imu_finish_tick(p);
    }
}

// ---------------------------------------------------------------------------
// API
// ---------------------------------------------------------------------------

void pl_imu_stream_init(void)
{
    imu_pcb = udp_new();
    if (imu_pcb == NULL)
        send_message("ERROR: Could not create IMU UDP PCB\r\n");
    imu_stream_pkts_sent = 0;
}

uint32_t pl_imu_stream_set(uint32_t mask, uint32_t period_ms)
{
    if (period_ms == 0) period_ms = IMU_PERIOD_MS_DEFAULT;
    if (period_ms < IMU_PERIOD_MS_MIN) period_ms = IMU_PERIOD_MS_MIN;
    if (period_ms > IMU_PERIOD_MS_MAX) period_ms = IMU_PERIOD_MS_MAX;
    imu_period_ms = period_ms;

    XTime now; XTime_GetTime(&now);
    for (int port = 0; port < 2; port++) {
        imu_port_t *p = &imu_port[port];
        int has = port ? pl_has_iic_b : pl_has_iic_a;
        int want = (mask >> port) & 1;
        if (want && !has) continue;           // fabric can't serve it -- drop bit

        if (want && !p->running) {
            uint8_t mode = 0;
            XIic_DynInit(p->base);
            if (!pl_imu_ndof_enter(p->base, &mode)) {
                send_message("IMU stream port %c: no BNO055 / NDOF entry "
                             "failed -- not started\r\n", port ? 'B' : 'A');
                continue;
            }
            p->opr_mode = mode;
            p->seq = 0;
            p->tick_count = 0;
            p->burst_idx = 0;
            p->in_flight = 0;
            p->await_count = 0;
            p->await_idle = 0;
            p->hk_due = 1;                    // first tick fetches temp/calib
            p->calib_stat = 0xFF;
            p->temp_c = 0;
            p->iic_errors = p->send_drops = p->consec_errors = 0;
            // Stagger port B half a period so the two ports' bursts interleave
            // instead of landing their FIFO work in the same passes.
            p->next_tick = now + imu_ms_to_ticks(port ? period_ms / 2 : 0);
            p->running = 1;
        } else if (!want && p->running) {
            p->running = 0;
            if (p->in_flight) XIic_DynInit(p->base);   // abort mid-transfer cleanly
            p->in_flight = 0;
        }
    }
    return pl_imu_stream_mask();
}

void pl_imu_stream_stop_all(void)
{
    for (int port = 0; port < 2; port++) {
        imu_port_t *p = &imu_port[port];
        if (p->running && p->in_flight) XIic_DynInit(p->base);
        p->running = 0;
        p->in_flight = 0;
        p->await_count = 0;
        p->await_idle = 0;
    }
}

int pl_imu_stream_active(int port) { return imu_port[port & 1].running; }

uint32_t pl_imu_stream_period_ms(void) { return imu_period_ms; }

uint32_t pl_imu_stream_mask(void)
{
    return (imu_port[0].running ? 1u : 0u) | (imu_port[1].running ? 2u : 0u);
}

// Time the loop spent elsewhere before a gap counts as "we weren't looking"
// rather than ordinary scheduling jitter. Well above a normal loop period,
// well under the transfer deadline.
#define IMU_SERVICE_GAP_MS 2

void pl_imu_stream_service(void)
{
    // Credit back time this service was not called at all. The transfer
    // deadline exists to catch a bus that stopped answering, and that is only
    // judgeable while we are actually polling. Core 0 legitimately disappears
    // for long stretches -- a full cable test parks in usleep for ~100 ms,
    // dump_bram is slow -- and charging that absence to a healthy in-flight
    // transfer would count a phantom I2C error. Sixteen of those in a row
    // would auto-stop a perfectly good port, so this is a correctness fix,
    // not a cosmetic one.
    XTime now; XTime_GetTime(&now);
    if (imu_last_service) {
        XTime gap = now - imu_last_service;
        if (gap > imu_ms_to_ticks(IMU_SERVICE_GAP_MS)) {
            for (int i = 0; i < 2; i++)
                if (imu_port[i].running)
                    imu_port[i].deadline += gap;
        }
    }
    imu_last_service = now;

    imu_service_port(&imu_port[0], 0);
    imu_service_port(&imu_port[1], 1);
}

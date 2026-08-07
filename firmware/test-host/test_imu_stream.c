// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Host regression tests for the pl_imu_stream.c state machine, run against the
// simulated IIC core + BNO055 in imu_host_mock.c. What silicon must still
// prove is only the IIC core's acceptance of the preloaded combined command
// sequence -- everything decidable in logic is decided here: tick cadence,
// packet layout, sequence numbering, NACK/timeout recovery, auto-stop,
// housekeeping cadence, dual-port independence, and drop accounting.

#include "imu_host_mock.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int failures;
#define CHECK(cond, ...) do { \
    if (!(cond)) { failures++; printf("  FAIL %s:%d  ", __FILE__, __LINE__); \
                   printf(__VA_ARGS__); printf("\n"); } } while (0)

// Drive the main loop: service + advance, like core 0 does. 50 us per pass is
// pessimistic (the real loop spins far faster when idle).
static void run_ms(int ms)
{
    for (int i = 0; i < ms * 20; i++) {
        pl_imu_stream_service();
        mock_advance_us(50);
    }
}

// The real core-0 loop revisits this service far faster than 50 us -- it is
// servicing lwIP and a 33 us sample budget, so passes are microseconds apart.
// That speed is what exposes bus-state races (a burst's STOP is still
// releasing when the next burst is queued), so ordering is checked at this
// cadence rather than the coarse one.
static void run_ms_fast(int ms)
{
    for (int i = 0; i < ms * 500; i++) {
        pl_imu_stream_service();
        mock_advance_us(2);
    }
}

static uint32_t pkt_word(int n, int w)
{
    uint32_t v;
    memcpy(&v, mock_pkts[n].data + 4 * w, 4);
    return v;
}
static int16_t pkt_h(int n, int idx)   // payload halfword idx 0..9
{
    int16_t v;
    memcpy(&v, mock_pkts[n].data + 32 + 2 * idx, 2);
    return v;
}

static void test_basic_stream(void)
{
    printf("basic_stream: cadence, layout, seq, payload, timestamp\n");
    mock_reset();
    mock_timestamp_lo = 0x11223344; mock_timestamp_hi = 0x5;

    uint32_t active = pl_imu_stream_set(1, 10);      // port A, 100 Hz
    CHECK(active == 1, "active=%u", active);
    CHECK(mock_ndof_calls[0] == 1 && mock_ndof_calls[1] == 0, "ndof calls");

    run_ms(100);                                      // ~10 samples
    CHECK(mock_bad_sequence == 0, "bad IIC sequences: %d", mock_bad_sequence);
    CHECK(mock_n_pkts >= 9 && mock_n_pkts <= 11, "pkts=%d (want ~10)", mock_n_pkts);

    CHECK(mock_pkts[0].len == 52, "len=%u", mock_pkts[0].len);
    CHECK(pkt_word(0, 0) == UNIFIED_MAGIC, "magic=0x%08X", pkt_word(0, 0));
    // Spelled out as a literal, NOT built from STREAM_TYPE_IMU: this is the wire
    // wire format, so the test has to fail when the constant moves rather than
    // follow it. 3 = IMU, 1 = unified version, 0 = port A in the flags field.
    CHECK(pkt_word(0, 1) == (3u | (1u << 8) | (0u << 16)), "type_ver=0x%08X", pkt_word(0, 1));
    CHECK(pkt_word(0, 2) == 0x11223344 && pkt_word(0, 3) == 0x5, "timestamp");
    for (int n = 0; n < mock_n_pkts; n++)
        CHECK(pkt_word(n, 4) == (uint32_t)n, "seq[%d]=%u", n, pkt_word(n, 4));
    CHECK((pkt_word(0, 5) & 0xFFFF) == 10, "period=%u", pkt_word(0, 5) & 0xFFFF);

    // Payload order: quat wxyz, acc xyz, gyr xyz.
    for (int i = 0; i < 4; i++)
        CHECK(pkt_h(0, i) == mock_bno[0].quat[i], "quat[%d]=%d", i, pkt_h(0, i));
    for (int i = 0; i < 3; i++)
        CHECK(pkt_h(0, 4 + i) == mock_bno[0].acc[i], "acc[%d]=%d", i, pkt_h(0, 4 + i));
    for (int i = 0; i < 3; i++)
        CHECK(pkt_h(0, 7 + i) == mock_bno[0].gyr[i], "gyr[%d]=%d", i, pkt_h(0, 7 + i));

    // Housekeeping runs on the first tick: AUX1 carries calib/mode/temp.
    uint32_t aux1 = pkt_word(1, 6);
    CHECK((aux1 & 0xFF) == 0xC3, "calib=0x%02X", aux1 & 0xFF);
    CHECK(((aux1 >> 8) & 0xFF) == BNO055_MODE_NDOF, "mode");
    CHECK(((aux1 >> 16) & 0xFF) == 23, "temp=%u", (aux1 >> 16) & 0xFF);

    pl_imu_stream_set(0, 0);
    CHECK(pl_imu_stream_mask() == 0, "stop");
}

static void test_live_sensor_update(void)
{
    printf("live_sensor_update: later packets carry later sensor values\n");
    mock_reset();
    pl_imu_stream_set(1, 10);
    run_ms(30);
    int before = mock_n_pkts;
    mock_bno[0].quat[0] = -12345;
    run_ms(30);
    CHECK(mock_n_pkts > before + 1, "no packets after update");
    CHECK(pkt_h(mock_n_pkts - 1, 0) == -12345, "stale quat: %d", pkt_h(mock_n_pkts - 1, 0));
    pl_imu_stream_set(0, 0);
}

static void test_nack_recovery(void)
{
    printf("nack_recovery: transient NACK skips ticks, then resumes\n");
    mock_reset();
    pl_imu_stream_set(1, 10);
    run_ms(50);
    int before_pkts = mock_n_pkts, before_inits = mock_dyninit_calls[0];
    mock_bno[0].present = 0;                       // unplug
    run_ms(50);                                    // ~5 failed ticks
    int failed_pkts = mock_n_pkts;
    CHECK(failed_pkts <= before_pkts + 1, "packets while unplugged");
    CHECK(mock_dyninit_calls[0] > before_inits, "no DynInit recovery");
    CHECK(pl_imu_stream_active(0), "gave up too early");
    mock_bno[0].present = 1;                       // replug before auto-stop
    run_ms(50);
    CHECK(mock_n_pkts > failed_pkts + 2, "did not resume");
    // Health telemetry: iic_errors visible in AUX0.
    CHECK(((pkt_word(mock_n_pkts - 1, 5) >> 16) & 0xFF) > 0, "iic_errors not reported");
    pl_imu_stream_set(0, 0);
}

static void test_auto_stop(void)
{
    printf("auto_stop: a dead IMU shuts its port off after 16 consecutive errors\n");
    mock_reset();
    pl_imu_stream_set(1, 10);
    run_ms(20);
    mock_bno[0].present = 0;
    run_ms(300);                                   // >16 failed ticks
    CHECK(!pl_imu_stream_active(0), "still running");
    int pkts = mock_n_pkts;
    run_ms(50);
    CHECK(mock_n_pkts == pkts, "still sending after auto-stop");
}

static void test_wedged_bus_timeout(void)
{
    printf("wedged_bus_timeout: no data and no NACK -> deadline recovery\n");
    mock_reset();
    pl_imu_stream_set(1, 10);
    run_ms(20);
    int before_inits = mock_dyninit_calls[0];
    mock_bno[0].wedge = 1;
    run_ms(100);
    CHECK(mock_dyninit_calls[0] > before_inits, "no timeout recovery");
    mock_bno[0].wedge = 0;
    int pkts = mock_n_pkts;
    run_ms(50);
    CHECK(mock_n_pkts > pkts + 2, "did not resume after wedge cleared");
    pl_imu_stream_set(0, 0);
}

static void test_dual_port(void)
{
    printf("dual_port: independent seq/payload, no cross-talk\n");
    mock_reset();
    uint32_t active = pl_imu_stream_set(3, 10);
    CHECK(active == 3, "active=%u", active);
    run_ms(100);
    CHECK(mock_bad_sequence == 0, "bad sequences");
    int na = 0, nb = 0; uint32_t seq_a = 0, seq_b = 0;
    for (int n = 0; n < mock_n_pkts; n++) {
        int port = (pkt_word(n, 1) >> 16) & 1;
        if (port == 0) { CHECK(pkt_word(n, 4) == seq_a++, "seq A"); na++;
                         CHECK(pkt_h(n, 0) == mock_bno[0].quat[0], "A quat"); }
        else           { CHECK(pkt_word(n, 4) == seq_b++, "seq B"); nb++;
                         CHECK(pkt_h(n, 0) == mock_bno[1].quat[0], "B quat"); }
    }
    CHECK(na >= 9 && nb >= 9, "port counts a=%d b=%d", na, nb);
    pl_imu_stream_set(0, 0);
}

static void test_fabric_gating(void)
{
    printf("fabric_gating: a port without an IIC is dropped from the mask\n");
    mock_reset();
    pl_has_iic_b = 0;                              // acq_imu_port_a fabric
    uint32_t active = pl_imu_stream_set(3, 10);
    CHECK(active == 1, "active=%u (want A only)", active);
    CHECK(mock_ndof_calls[1] == 0, "touched port B's absent IIC");
    pl_imu_stream_set(0, 0);
    pl_has_iic_b = 1;
}

static void test_ndof_failure(void)
{
    printf("ndof_failure: chip that won't enter NDOF never arms\n");
    mock_reset();
    mock_ndof_fail[0] = 1;
    uint32_t active = pl_imu_stream_set(1, 10);
    CHECK(active == 0, "armed despite NDOF failure");
    run_ms(30);
    CHECK(mock_n_pkts == 0, "packets from unarmed port");
}

static void test_send_drop_accounting(void)
{
    printf("send_drop_accounting: pbuf exhaustion -> SEQ gap + drop counter\n");
    mock_reset();
    pl_imu_stream_set(1, 10);
    run_ms(30);
    int before = mock_n_pkts;
    uint32_t seq_before = pkt_word(before - 1, 4);
    mock_pbuf_fail = 1;
    run_ms(30);                                    // samples acquired, sends dropped
    CHECK(mock_n_pkts == before, "packets sent during pbuf famine");
    mock_pbuf_fail = 0;
    run_ms(30);
    uint32_t seq_after = pkt_word(before, 4);      // first packet after famine
    CHECK(seq_after > seq_before + 2, "no SEQ gap: %u -> %u", seq_before, seq_after);
    CHECK(((pkt_word(before, 5) >> 24) & 0xFF) > 0, "send_drops not reported");
    pl_imu_stream_set(0, 0);
}

static void test_stop_all_mid_flight(void)
{
    printf("stop_all_mid_flight: fabric teardown aborts cleanly\n");
    mock_reset();
    pl_imu_stream_set(3, 10);
    // Advance just enough that a transfer is very likely in flight.
    for (int i = 0; i < 200; i++) { pl_imu_stream_service(); mock_advance_us(50); }
    pl_imu_stream_stop_all();
    CHECK(pl_imu_stream_mask() == 0, "not stopped");
    int pkts = mock_n_pkts;
    run_ms(50);
    CHECK(mock_n_pkts == pkts, "sent after stop_all");
}

static void test_bus_ordering(void)
{
    printf("bus_ordering: the byte count follows BUS_BUSY, never precedes it\n");
    // The vendor's blocking XIic_DynRecv writes the dynamic STOP+count only
    // after the core has taken the bus. The mock counts any count-before-busy
    // as a bad sequence, so a regression to speculative preloading fails here
    // rather than at the bench.
    mock_reset();
    pl_imu_stream_set(3, 10);
    run_ms(120);
    CHECK(mock_bad_sequence == 0,
          "command FIFO deviated from the proven ordering: %d", mock_bad_sequence);
    CHECK(mock_n_pkts > 15, "no traffic to judge ordering by (%d pkts)", mock_n_pkts);

    // Again at main-loop speed. Here the previous burst's STOP is often still
    // releasing the bus when the next burst is queued, so a naive "is the bus
    // busy?" test would see the OLD transaction's busy and hand over the byte
    // count before this burst's addresses ever reached the wire.
    mock_reset();
    pl_imu_stream_set(3, 10);
    run_ms_fast(60);
    CHECK(mock_bad_sequence == 0,
          "count written against a stale BUS_BUSY: %d violations", mock_bad_sequence);
    CHECK(mock_n_pkts > 8, "no traffic at loop speed (%d pkts)", mock_n_pkts);

    // An absent device NACKs its address and the core never takes the bus.
    // The machine must notice the error rather than sit out its 20 ms deadline,
    // so a dead port still costs only one tick.
    mock_reset();
    mock_bno[0].present = 0;
    pl_imu_stream_set(1, 10);
    int before = mock_dyninit_calls[0];
    run_ms(30);            // 3 ticks; deadline alone would allow barely one
    CHECK(mock_dyninit_calls[0] - before >= 2,
          "NACK not detected promptly (%d recoveries in 30 ms)",
          mock_dyninit_calls[0] - before);
    pl_imu_stream_set(0, 0);
}

static void test_service_gap(void)
{
    printf("service_gap: a long absence from the loop is not the bus's fault\n");
    // Core 0 can legitimately stop servicing for a long time -- a full cable
    // test parks in usleep for ~100 ms, dump_bram is slow, a console flood
    // stalls. A transfer in flight across that gap is still healthy; charging
    // the absence to the transfer deadline would count a bogus I2C error, and
    // enough of them in a row would auto-stop a perfectly good port.
    mock_reset();
    pl_imu_stream_set(1, 10);
    // Deterministically stall WITH A TRANSFER IN FLIGHT: the first service
    // call after arming kicks burst 0 (next_tick == now), so the stall lands
    // squarely inside that transfer rather than on an idle machine.
    int errors_before = mock_dyninit_calls[0];
    int pkts_before = mock_n_pkts;

    for (int i = 0; i < 8; i++) {
        pl_imu_stream_service();       // kicks a burst (or resumes one)
        mock_advance_us(100000);       // the loop is elsewhere -- cable test, etc.
        pl_imu_stream_service();       // first look after the stall
        run_ms(15);                    // let the tick finish normally
    }
    CHECK(mock_dyninit_calls[0] == errors_before,
          "%d bogus bus recoveries from service gaps",
          mock_dyninit_calls[0] - errors_before);
    CHECK(pl_imu_stream_active(0), "port auto-stopped because the loop was busy");
    CHECK(mock_n_pkts > pkts_before + 8, "stream did not continue across stalls");
    CHECK(mock_bad_sequence == 0, "ordering broke across stalls");
    pl_imu_stream_set(0, 0);
}

static void test_end_of_read_nack(void)
{
    printf("end_of_read_nack: the terminating NACK is not a failure\n");
    // Every successful master receive ends with the core NACKing the final
    // byte, latching TX_ERROR. Treating that as an error discards every burst:
    // the stream produces nothing and the port auto-stops after 16 "errors" --
    // which is exactly how this presented on hardware. The mock latches
    // TX_ERROR on every completed read, so this test is the guard.
    mock_reset();
    pl_imu_stream_set(1, 10);
    run_ms(60);
    CHECK(mock_n_pkts >= 5, "no samples survived the end-of-read NACK (%d pkts)",
          mock_n_pkts);
    CHECK(pl_imu_stream_active(0), "port auto-stopped on normal end-of-read NACKs");

    // The 2-byte housekeeping burst is the one most exposed: with so few bytes
    // the terminating NACK lands almost immediately after the data. If it were
    // mishandled, calib/temp would never refresh and AUX1 would stay at its
    // 0xFF/0 defaults forever.
    int with_hk = -1;
    for (int n = 0; n < mock_n_pkts; n++)
        if ((pkt_word(n, 6) & 0xFF) == 0xC3) { with_hk = n; break; }
    CHECK(with_hk >= 0, "housekeeping burst never completed (calib never set)");
    if (with_hk >= 0)
        CHECK(((pkt_word(with_hk, 6) >> 16) & 0xFF) == 23, "temperature not read");
    pl_imu_stream_set(0, 0);
}

static void test_deadline_survives_slow_service(void)
{
    printf("deadline_slow_service: the wedge detector must still fire\n");
    // The service-gap credit exists so a busy command loop cannot manufacture
    // I2C errors -- but it must give back only the EXCESS. Crediting the whole
    // interval advances the deadline 1:1 with wall clock, and since that
    // deadline is the ONLY wedged-bus detector, the port would then never
    // recover, never auto-stop, and go quiet with iic_errors reading 0.
    //
    // Must be driven ABOVE IMU_SERVICE_GAP_MS (2 ms), or the credit path never
    // runs at all -- which is why run_ms()'s 50 us cadence cannot catch this.
    mock_reset();
    pl_imu_stream_set(1, 10);
    run_ms(20);
    mock_bno[0].wedge = 1;
    int before = mock_dyninit_calls[0];
    for (int i = 0; i < 200; i++) {          // 200 x 5 ms = 1 s, 50x the deadline
        pl_imu_stream_service();
        mock_advance_us(5000);
    }
    CHECK(mock_dyninit_calls[0] > before,
          "wedged bus never detected under slow service (deadline unreachable)");
    pl_imu_stream_set(0, 0);
}

static void test_lifecycle(void)
{
    printf("lifecycle: fabric-swap stop then restart, and adding a port live\n");
    mock_reset();
    pl_imu_stream_set(1, 10);
    run_ms(50);
    int first_run = mock_n_pkts;
    CHECK(first_run > 3, "no packets in the first run");
    uint32_t last_seq = pkt_word(first_run - 1, 4);

    // What set_config does when the fabric (and its IICs) are torn down.
    pl_imu_stream_stop_all();
    run_ms(30);
    CHECK(mock_n_pkts == first_run, "sent packets after the fabric went away");

    // Restart on the new fabric: SEQ must restart at 0, so the host's loss
    // check sees a stream restart (backward jump) rather than a huge gap.
    pl_imu_stream_set(1, 10);
    run_ms(50);
    CHECK(mock_n_pkts > first_run + 3, "did not resume after restart");
    CHECK(pkt_word(first_run, 4) == 0,
          "SEQ did not restart at 0 (got %u after %u)",
          pkt_word(first_run, 4), last_seq);
    CHECK(mock_bad_sequence == 0, "ordering broke across the restart");

    // Adding port B while A streams must not disturb A: its SEQ keeps
    // counting, and only B starts from 0. (The plugin and net.py both do this
    // when a second headstage appears.)
    pl_imu_stream_set(0, 0);      // firmware state persists across mock_reset()
    mock_reset();
    pl_imu_stream_set(1, 10);
    run_ms(50);
    int before_b = mock_n_pkts;
    uint32_t seq_a_before = pkt_word(before_b - 1, 4);
    int a_arms_before = mock_ndof_calls[0];
    CHECK(pl_imu_stream_set(3, 10) == 3, "port B did not join");
    CHECK(mock_ndof_calls[0] == a_arms_before,
          "port A was re-armed when B joined (NDOF re-entered, losing fusion state)");
    CHECK(mock_ndof_calls[1] == 1, "port B was not armed exactly once");
    run_ms(50);
    uint32_t seq_a = seq_a_before, seq_b = 0;
    int b_seen = 0, a_ok = 1, b_ok = 1;
    for (int n = before_b; n < mock_n_pkts; n++) {
        int port = (pkt_word(n, 1) >> 16) & 1;
        if (port == 0) { if (pkt_word(n, 4) != ++seq_a) a_ok = 0; }
        else { if (pkt_word(n, 4) != seq_b++) b_ok = 0; b_seen++; }
    }
    CHECK(a_ok, "port A's SEQ was disturbed when B joined");
    CHECK(b_ok, "port B's SEQ did not start clean");
    CHECK(b_seen > 3, "port B produced almost nothing (%d)", b_seen);
    pl_imu_stream_set(0, 0);
}

static void test_period_clamp(void)
{
    printf("period_clamp: out-of-range periods clamp to [10,1000]\n");
    mock_reset();
    pl_imu_stream_set(1, 3);
    CHECK(pl_imu_stream_period_ms() == 10, "min clamp: %u", pl_imu_stream_period_ms());
    pl_imu_stream_set(1, 99999);
    CHECK(pl_imu_stream_period_ms() == 1000, "max clamp: %u", pl_imu_stream_period_ms());
    pl_imu_stream_set(0, 0);
    // 50 ms period -> ~6 packets in 300 ms.
    mock_reset();
    pl_imu_stream_set(1, 50);
    run_ms(300);
    CHECK(mock_n_pkts >= 5 && mock_n_pkts <= 7, "50ms cadence: %d pkts", mock_n_pkts);
    pl_imu_stream_set(0, 0);
}

// With IMU_TEST_DUMP=<path> set, run a clean dual-port capture and write the
// raw datagrams (u16-LE length prefix each) for the Python side to parse with
// net.py's real parse_imu_packet -- the cross-implementation check.
static void dump_packets(const char *path)
{
    mock_reset();
    mock_timestamp_lo = 0xDEAD0001; mock_timestamp_hi = 0x2;
    pl_imu_stream_set(3, 10);
    run_ms(100);
    pl_imu_stream_set(0, 0);
    FILE *f = fopen(path, "wb");
    if (!f) { failures++; printf("  FAIL cannot open %s\n", path); return; }
    for (int n = 0; n < mock_n_pkts; n++) {
        uint8_t l[2] = { (uint8_t)(mock_pkts[n].len & 0xFF),
                         (uint8_t)(mock_pkts[n].len >> 8) };
        fwrite(l, 1, 2, f);
        fwrite(mock_pkts[n].data, 1, mock_pkts[n].len, f);
    }
    fclose(f);
    printf("dumped %d packets to %s\n", mock_n_pkts, path);
}

int main(void)
{
    pl_imu_stream_init();
    test_basic_stream();
    test_live_sensor_update();
    test_nack_recovery();
    test_auto_stop();
    test_wedged_bus_timeout();
    test_dual_port();
    test_fabric_gating();
    test_ndof_failure();
    test_send_drop_accounting();
    test_stop_all_mid_flight();
    test_bus_ordering();
    test_service_gap();
    test_deadline_survives_slow_service();
    test_end_of_read_nack();
    test_lifecycle();
    test_period_clamp();
    const char *dump = getenv("IMU_TEST_DUMP");
    if (dump) dump_packets(dump);
    if (failures) { printf("TB_FAIL  Errors: %d\n", failures); return 1; }
    printf("TB_PASS  Errors: 0\n");
    return 0;
}

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
    CHECK(pkt_word(0, 1) == (4u | (1u << 8) | (0u << 16)), "type_ver=0x%08X", pkt_word(0, 1));
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
// net.py's real parse_imu_packet -- the cross-implementation contract test.
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
    test_period_clamp();
    const char *dump = getenv("IMU_TEST_DUMP");
    if (dump) dump_packets(dump);
    if (failures) { printf("TB_FAIL  Errors: %d\n", failures); return 1; }
    printf("TB_PASS  Errors: 0\n");
    return 0;
}

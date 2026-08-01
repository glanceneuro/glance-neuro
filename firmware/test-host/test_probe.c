// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Host tests for the BOUNDED I2C primitives -- pl_imu_read.c, pl_i2c_probe.c
// and pl_imu_detect.c -- against the simulated AXI IIC core + BNO055.
//
// These files carry the fixes for the two worst bugs this firmware has had:
// a command handler that could spin forever on BUS_BUSY (a hung board and a
// watchdog reset mid-experiment), and a reply that shipped uninitialized core-0
// stack to the host, where it decoded as a perfectly plausible quaternion. Both
// were verified only by compiling, because no test compiled these files at all;
// this binary exists so a revert of either fails here instead of at the bench.
//
// Separate from test_imu_stream because pl_imu_read.c defines the real
// pl_imu_ndof_enter, which collides with the mock's stand-in -- hence
// IMU_PROBE_TEST, which drops the stand-in.

#include "imu_host_mock.h"
#include "pl_i2c_probe.h"
#include "pl_imu_read.h"     // the real declarations -- the stub xil_types.h
                             // supplies UINTPTR, so this header includes fine
#include <stdio.h>
#include <string.h>

int pl_imu_detect_run(imu_detect_response_t *out, int probe_a, int probe_b);

static int failures;
#define CHECK(cond, ...) do { \
    if (!(cond)) { failures++; printf("  FAIL %s:%d  ", __FILE__, __LINE__); \
                   printf(__VA_ARGS__); printf("\n"); } } while (0)

// Leave a recognizable pattern on the stack so an uninitialized read shows up
// as that pattern rather than as an innocuous zero.
static void dirty_the_stack(void)
{
    volatile uint8_t junk[512];
    for (size_t i = 0; i < sizeof(junk); i++) junk[i] = 0x5A;
    (void)junk;
}

static void test_early_return_is_zeroed(void)
{
    printf("early_return_zeroed: a failed read must not transmit stack\n");
    mock_reset();
    mock_bno[0].present = 0;            // nothing ACKs at 0x28
    mock_i2c_present[BNO055_I2C_ADDR] = 0;

    dirty_the_stack();
    imu_sample_response_t out;
    memset(&out, 0x5A, sizeof(out));    // caller's buffer is dirty too
    int ok = pl_imu_read_sample(0, &out);

    CHECK(!ok, "reported success with no device");
    // Every payload field must be zero: the handler transmits all 32 bytes
    // regardless of the return value.
    CHECK(out.quat_w == 0 && out.quat_x == 0 && out.quat_y == 0 && out.quat_z == 0,
          "quaternion is uninitialized stack: %d %d %d %d",
          out.quat_w, out.quat_x, out.quat_y, out.quat_z);
    CHECK(out.acc_x == 0 && out.acc_y == 0 && out.acc_z == 0, "accel not zeroed");
    CHECK(out.gyr_x == 0 && out.gyr_y == 0 && out.gyr_z == 0, "gyro not zeroed");
    CHECK(out.calib_stat == 0 && out.temp_c == 0, "calib/temp not zeroed");
    CHECK(out.reserved == 0, "reserved not zeroed");
    CHECK(out.version == IMUREAD_VERSION, "version missing");
    CHECK(out.status & IMUREAD_R_NOACK, "status does not report the NACK");
}

static void test_bounded_on_dead_bus(void)
{
    printf("bounded_on_dead_bus: a line that never goes busy must not spin\n");
    // The vendor's XIic_DynSend/DynRecv spin on BUS_BUSY with no exit. This is
    // reached from a TCP command handler, so an unbounded wait is a hung board.
    // The runner wraps this binary in `timeout`, so a revert hangs -> fails.
    mock_reset();
    mock_bno[0].never_busy = 1;

    uint8_t val = 0;
    uint64_t t0 = 0; XTime_GetTime(&t0);
    int ok = pl_imu_bno_read(IMUDET_A_BASE, BNO055_REG_OPR_MODE, &val, 1);
    uint64_t t1 = 0; XTime_GetTime(&t1);

    CHECK(!ok, "claimed success on a dead bus");
    CHECK((t1 - t0) <= 3 * 20000ull,
          "took %llu us -- deadline not enforced", (unsigned long long)(t1 - t0));

    // The detect path must be bounded too: rescan probes right after a fabric
    // swap, which is exactly when the pins are still floating.
    mock_reset();
    mock_bno[0].never_busy = 1;
    mock_bno[1].never_busy = 1;
    imu_detect_response_t d;
    pl_imu_detect_run(&d, 1, 1);
    CHECK(!(d.result_a & IMUDET_R_PRESENT), "reported an IMU on a dead bus");
    CHECK(d.version == IMUDET_VERSION, "detect version missing");
}

static void test_single_byte_read(void)
{
    printf("single_byte_read: the terminating NACK must not fail a 1-byte read\n");
    // The core arms NO_ACK before the address even goes out for a 1-byte read,
    // so TX_ERROR is set almost immediately. Treating that as fatal breaks
    // EVERY chip-ID and mode read -- and those are the reads detect_imu and
    // NDOF entry are built from, so the whole IMU would look absent.
    mock_reset();
    uint8_t mode = 0;
    CHECK(pl_imu_bno_read(IMUDET_A_BASE, BNO055_REG_OPR_MODE, &mode, 1),
          "1-byte read failed on a healthy device");
    CHECK((mode & 0x0F) == BNO055_MODE_NDOF, "wrong value: 0x%02X", mode);

    imu_detect_response_t d;
    mock_reset();
    pl_imu_detect_run(&d, 1, 0);
    CHECK(d.result_a & IMUDET_R_PRESENT, "healthy BNO055 not detected");
    CHECK(((d.result_a >> IMUDET_R_ID_SHIFT) & 0xFF) == BNO055_CHIP_ID,
          "chip id wrong");
    CHECK(d.result_b & IMUDET_R_ABSENT, "un-probed port not marked absent");
}

static void test_scan_is_address_only(void)
{
    printf("scan_address_only: a bus scan must send no data byte\n");
    // A one-byte write is a no-op only to register-pointer devices; to anything
    // that takes bare command bytes it IS a command, and a scan must never be
    // able to trigger a measurement or a soft reset on a device it is merely
    // looking for.
    mock_reset();
    mock_i2c_present[0x28] = 1;
    mock_i2c_present[0x50] = 1;

    i2c_scan_response_t scan;
    pl_i2c_scan(0, &scan);

    CHECK(scan.status == 0, "scan reported wedged: 0x%08X", scan.status);
    CHECK(scan.version == I2C_SCAN_VERSION, "version missing");
    CHECK(scan.bitmap[0x28 >> 3] & (1u << (0x28 & 7)), "missed the BNO055");
    CHECK(scan.bitmap[0x50 >> 3] & (1u << (0x50 & 7)), "missed the EEPROM");
    CHECK(!(scan.bitmap[0x40 >> 3] & (1u << (0x40 & 7))), "invented a device");

    // Every logged FIFO word must carry BOTH start and stop -- i.e. be an
    // address-only probe. A data byte would appear as a word with neither.
    int data_words = 0;
    for (int i = 0; i < mock_dtr_n; i++) {
        uint32_t w = mock_dtr_log[i];
        if (!(w & XIIC_TX_DYN_START_MASK)) data_words++;
    }
    CHECK(data_words == 0,
          "%d data byte(s) written during a scan -- probe is not address-only",
          data_words);
    CHECK(mock_dtr_n >= 100, "only %d probes emitted", mock_dtr_n);
}

static void test_eeprom_read_partial(void)
{
    printf("eeprom_read: a healthy read completes; a dead bus is bounded\n");
    mock_reset();
    mock_i2c_present[0x50] = 1;

    eeprom_read_response_t rd;
    pl_i2c_read(0, BNO055_I2C_ADDR, 1, BNO055_REG_QUA_DATA, 8, &rd);
    CHECK(rd.status == 0, "healthy read reported status %u", rd.status);
    CHECK(rd.nbytes == 8, "got %u of 8 bytes", rd.nbytes);
    CHECK(rd.version == EEPROM_READ_VERSION, "version missing");

    mock_reset();
    mock_bno[0].never_busy = 1;
    uint64_t t0 = 0; XTime_GetTime(&t0);
    pl_i2c_read(0, BNO055_I2C_ADDR, 1, 0, 8, &rd);
    uint64_t t1 = 0; XTime_GetTime(&t1);
    CHECK(rd.status != 0, "claimed success on a dead bus");
    CHECK((t1 - t0) <= 3 * 20000ull, "unbounded: %llu us",
          (unsigned long long)(t1 - t0));
}

int main(void)
{
    test_early_return_is_zeroed();
    test_bounded_on_dead_bus();
    test_single_byte_read();
    test_scan_is_address_only();
    test_eeprom_read_partial();
    if (failures) { printf("TB_FAIL  Errors: %d\n", failures); return 1; }
    printf("TB_PASS  Errors: 0\n");
    return 0;
}

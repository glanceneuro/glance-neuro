# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
"""Host-side tests for the IMU stream receive path in net.py.

Two layers:
  1. CROSS-CHECK: run the firmware host-test binary (firmware/test-host) with
     IMU_TEST_DUMP set, then parse the raw datagrams the (simulated) firmware
     actually emitted with net.py's real parse_imu_packet. Firmware C and host
     Python are two independent implementations of docs/protocol.md -- this
     test fails if they ever disagree on the wire format.
  2. SINK: run a real UnifiedSink on a loopback UDP port and prove the
     demux/fan-out/SEQ-gap machinery on synthetic IMU datagrams.

Run:  python3 remote/test_imu_host.py     (no board, no Xilinx tools)
"""
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import net  # noqa: E402  (net.py is import-safe; __main__ guard holds the CLI)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = 0


def check(cond, msg):
    global failures
    if not cond:
        failures += 1
        print(f"  FAIL {msg}")


# Mirrors mock_reset() in firmware/test-host/imu_host_mock.c.
def mock_quat(p, i): return 0x4000 - i * 1000 - p * 7
def mock_acc(p, i): return -981 + i * 100 + p * 3
def mock_gyr(p, i): return 160 * (i - 1) + p


def test_cross_check():
    print("cross-check: firmware-emitted datagrams parse correctly in net.py")
    dump = os.path.join(tempfile.mkdtemp(), "imu_pkts.bin")
    env = dict(os.environ, IMU_TEST_DUMP=dump)
    r = subprocess.run(
        ["bash", os.path.join(REPO, "firmware/test-host/run_imu_stream_test.sh")],
        env=env, capture_output=True, text=True)
    check(r.returncode == 0, f"firmware host test failed:\n{r.stdout}{r.stderr}")
    check("TB_PASS" in r.stdout, "no TB_PASS from firmware host test")
    if not os.path.exists(dump):
        check(False, "no dump produced")
        return

    raw = open(dump, "rb").read()
    pkts, off = [], 0
    while off + 2 <= len(raw):
        (ln,) = struct.unpack_from("<H", raw, off)
        pkts.append(raw[off + 2:off + 2 + ln])
        off += 2 + ln
    check(len(pkts) >= 18, f"only {len(pkts)} packets dumped")

    seq = {"A": None, "B": None}
    n_by_port = {"A": 0, "B": 0}
    for data in pkts:
        check(len(data) == net.IMU_PKT_BYTES, f"len {len(data)}")
        pkt = net.parse_imu_packet(data)
        check(pkt is not None, "parse returned None")
        if pkt is None:
            continue
        p = pkt["port"]
        pi = 0 if p == "A" else 1
        n_by_port[p] += 1
        # SEQ continuity per port.
        if seq[p] is not None:
            check(pkt["seq"] == seq[p] + 1, f"seq gap on {p}")
        seq[p] = pkt["seq"]
        # Engineering-unit round trip against the mock sensor values.
        for i in range(4):
            check(abs(pkt["quat"][i] - mock_quat(pi, i) / 16384.0) < 1e-9,
                  f"{p} quat[{i}] = {pkt['quat'][i]}")
        for i in range(3):
            check(abs(pkt["accel"][i] - mock_acc(pi, i) / 100.0) < 1e-9,
                  f"{p} accel[{i}] = {pkt['accel'][i]}")
            check(abs(pkt["gyro"][i] - mock_gyr(pi, i) / 16.0) < 1e-9,
                  f"{p} gyro[{i}] = {pkt['gyro'][i]}")
        check(pkt["timestamp"] == (0x2 << 32) | 0xDEAD0001, "timestamp")
        check(pkt["period_ms"] == 10, f"period {pkt['period_ms']}")
        if pkt["seq"] >= 1:
            # Housekeeping (temp/calib) lands after tick 0's packet is already
            # out: seq 0 reports the documented defaults (calib 0xFF, temp 0).
            check(pkt["temp_c"] == 23 + pi, f"temp {pkt['temp_c']}")
            check(pkt["calib"] == 0xC3, f"calib 0x{pkt['calib']:02X}")
        else:
            check(pkt["calib"] == 0xFF, "seq-0 calib default")
    check(n_by_port["A"] >= 9 and n_by_port["B"] >= 9,
          f"port counts {n_by_port}")
    print(f"  {len(pkts)} firmware datagrams parsed, ports {n_by_port}")


def make_imu_pkt(port, seq, qw=8192):
    hdr = struct.pack("<IIIIIIII", net.UNIFIED_MAGIC,
                      net.STREAM_TYPE_IMU | (1 << 8) | (port << 16),
                      0x1234, 0, seq, 10, 0xC3 | (0x0C << 8) | (25 << 16), 0)
    pay = struct.pack("<10h", qw, 1, 2, 3, 4, 5, 6, 7, 8, 9)
    return hdr + pay


def test_sink_demux():
    print("sink: demux, per-port SEQ gap accounting, subscriber fan-out")
    port = 47654
    sink = net.UnifiedSink(port=port, rcvbuf=1 << 20)
    if not sink.start():
        check(False, "sink would not start")
        return
    q = sink.subscribe_imu()
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Port A seq 0,1,2 then a gap to 5; port B seq 0 -- the B packet must
        # not disturb A's continuity. Plus one garbage datagram.
        for s in (0, 1, 2):
            tx.sendto(make_imu_pkt(0, s), ("127.0.0.1", port))
        tx.sendto(make_imu_pkt(1, 0), ("127.0.0.1", port))
        tx.sendto(b"not a packet", ("127.0.0.1", port))
        tx.sendto(make_imu_pkt(0, 5), ("127.0.0.1", port))
        deadline = time.time() + 5.0
        while sink.imu_pkts < 5 and time.time() < deadline:
            time.sleep(0.01)
        check(sink.imu_pkts == 5, f"imu_pkts={sink.imu_pkts}")
        check(sink.other_pkts >= 1, "garbage not counted as other")
        check(sink._imu_gaps[0] == 1, f"port A gaps={sink._imu_gaps[0]}")
        check(sink._imu_gaps[1] == 0, f"port B gaps={sink._imu_gaps[1]}")
        got = [net.parse_imu_packet(q.get(timeout=1.0)) for _ in range(5)]
        check(all(p is not None for p in got), "subscriber got unparseable data")
        check([p["seq"] for p in got if p["port"] == "A"] == [0, 1, 2, 5],
              "subscriber A seqs")
        check(got[0]["quat"][0] == 0.5, f"quat scale {got[0]['quat'][0]}")
    finally:
        tx.close()
        sink.unsubscribe_imu(q)
        sink.stop()


def main():
    test_cross_check()
    test_sink_demux()
    if failures:
        print(f"TB_FAIL  Errors: {failures}")
        return 1
    print("TB_PASS  Errors: 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())

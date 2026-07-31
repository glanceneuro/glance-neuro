# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
"""Host tests for rescan orchestration and the I2C/EEPROM decoders in net.py.

rescan is pure decision logic over the board protocol -- which fabric to load
for a given headstage population, and which channel-mask bits are physically
impossible on that fabric. That is exactly the part worth testing without
hardware, so this drives net.py against a simulated board that answers the
same command set the firmware does.

Run:  python3 remote/test_rescan.py     (no board needed)
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import net  # noqa: E402

failures = 0


def check(cond, msg):
    global failures
    if not cond:
        failures += 1
        print(f"  FAIL {msg}")


class MockBoard:
    """Answers the subset of the binary protocol rescan/i2c_scan/eeprom_read use.

    imu_a / imu_b say whether a BNO055 answers on that cable; chip_mask is the
    channel-enable the phase sweep would 'detect' (used to exercise the
    freed-lane correction).
    """

    def __init__(self, imu_a=False, imu_b=False, chip_mask=0x11, config=-1):
        self.imu_a, self.imu_b = imu_a, imu_b
        self.chip_mask = chip_mask
        self.config = config
        self.commands = []          # (cmd_id, param1, param2) in order
        self.applied_mask = None
        self.i2c_devices = {0: [0x28, 0x50], 1: []}
        self.eeprom = bytes(range(32))

    def send(self, cmd_id, param1=0, param2=0, timeout=0.5):
        self.commands.append((cmd_id, param1, param2))
        if cmd_id == net.CMD_PL_STATUS:
            flags = (1 if self.config in (0, 2, 3, 4) else 0) | 2
            return True, struct.pack('<iI', self.config, flags)
        if cmd_id == net.CMD_SET_CONFIG:
            self.config = param1
            is_acq = 1 if param1 in (0, 2, 3, 4) else 0
            return True, struct.pack('<iII', 0, 4045568, is_acq | 2)
        if cmd_id == net.CMD_DETECT_IMU:
            def word(present, has_iic):
                if not has_iic:
                    return net.IMUDET_R_ABSENT
                return (0x3 | (0xA0 << 8) | (0xC0 << 24)) if present else (0xC0 << 24)
            # scan fabric (1) has both IICs; acq_imu_* have per-port IICs.
            iic = {1: (True, True), 2: (True, True), 3: (True, False),
                   4: (False, True)}.get(self.config, (False, False))
            if not any(iic):
                return False, None
            return True, struct.pack('<III', word(self.imu_a, iic[0]),
                                     word(self.imu_b, iic[1]),
                                     net.IMUDET_VERSION)
        if cmd_id == net.CMD_SET_CHANNEL_ENABLE:
            self.applied_mask = param1
            return True, None
        if cmd_id == net.CMD_I2C_SCAN:
            bitmap = bytearray(16)
            for a in self.i2c_devices.get(param1 & 1, []):
                bitmap[a >> 3] |= 1 << (a & 7)
            return True, struct.pack('<I', 0) + bytes(bitmap) + \
                struct.pack('<I', net.I2CSCAN_VERSION)
        if cmd_id == net.CMD_EEPROM_READ:
            n = param2 & 0xFF
            off = (param2 >> 8) & 0xFFFF
            data = self.eeprom[off:off + n].ljust(32, b'\0')
            return True, struct.pack('<II', 0, min(n, len(self.eeprom) - off)) + \
                data + struct.pack('<I', net.EEPROMRD_VERSION)
        return True, None


class MockDetection:
    """Stand-in for the phase-sweep result rescan post-processes."""
    def __init__(self, mask):
        self.success = True
        self.chips_detected = True
        self.optimal_channel_mask = mask

    def get_channel_summary(self):
        return f"mask 0x{self.optimal_channel_mask:02X}"


def install_mock(board, detection_mask=0x11):
    """Point net.py's board-facing calls at the mock. Returns a restore fn."""
    saved = (net.send_binary_command, net.run_detection, net.validator)

    net.send_binary_command = lambda sock, cmd_id, param1=0, param2=0, \
        timeout=0.5: board.send(cmd_id, param1, param2, timeout)
    net.run_detection = lambda sock, verbose=True: MockDetection(detection_mask)

    class V:
        def __init__(self):
            self.mask = None

        def set_channel_enable(self, m):
            self.mask = m
    net.validator = V()

    def restore():
        net.send_binary_command, net.run_detection, net.validator = saved
    return restore


def test_fabric_selection():
    print("fabric_selection: the IMU census picks the matching fabric")
    cases = [
        (False, False, "acquisition", 0),
        (True,  False, "acq_imu_port_a", 3),
        (False, True,  "acq_imu_port_b", 4),
        (True,  True,  "acq_imu_both", 2),
    ]
    for imu_a, imu_b, want_name, want_sel in cases:
        board = MockBoard(imu_a=imu_a, imu_b=imu_b)
        restore = install_mock(board, detection_mask=0x11)
        try:
            r = net.rescan(None)
        finally:
            restore()
        check(r is not None, f"rescan returned None for A={imu_a} B={imu_b}")
        if r is None:
            continue
        check(r["fabric"] == want_name,
              f"A={imu_a} B={imu_b} -> {r['fabric']}, want {want_name}")
        check(board.config == want_sel, f"board left on selector {board.config}")
        check(r["imu_a"] == imu_a and r["imu_b"] == imu_b, "IMU census echoed")
        # It must census on the scan fabric first, then load the target.
        configs = [p1 for (c, p1, _) in board.commands if c == net.CMD_SET_CONFIG]
        check(configs == [net.CONFIGS["scan"], want_sel],
              f"config sequence {configs}")
        # And it must stop streaming before swapping fabrics.
        check(board.commands[1][0] == net.CMD_STOP, "did not stop before set_config")


def test_freed_lane_correction():
    print("freed_lane_correction: impossible mask bits are removed and re-applied")
    # Port A has an IMU -> acq_imu_port_a, whose A.CIPO1 lanes (bits 2|3) have
    # no LVDS pair. A sweep that 'detects' them must not reach the board.
    board = MockBoard(imu_a=True, imu_b=False)
    restore = install_mock(board, detection_mask=0x1F)   # bits 0,1,2,3,4
    try:
        r = net.rescan(None)
    finally:
        restore()
    check(r is not None, "rescan returned None")
    check(board.applied_mask == 0x13, f"applied 0x{board.applied_mask:02X}, want 0x13")
    check(r["detection"].optimal_channel_mask == 0x13, "returned mask not corrected")

    # acq_imu_both frees both CIPO1 pairs (bits 2|3 and 6|7).
    board = MockBoard(imu_a=True, imu_b=True)
    restore = install_mock(board, detection_mask=0xFF)
    try:
        net.rescan(None)
    finally:
        restore()
    check(board.applied_mask == 0x33, f"applied 0x{board.applied_mask:02X}, want 0x33")

    # A clean mask on the same fabric must be left completely alone.
    board = MockBoard(imu_a=True, imu_b=True)
    restore = install_mock(board, detection_mask=0x33)
    try:
        net.rescan(None)
    finally:
        restore()
    check(board.applied_mask is None, "re-applied an already-valid mask")

    # Plain acquisition frees nothing -- all 8 lanes are real.
    board = MockBoard(imu_a=False, imu_b=False)
    restore = install_mock(board, detection_mask=0xFF)
    try:
        net.rescan(None)
    finally:
        restore()
    check(board.applied_mask is None, "corrected a mask on the plain acq fabric")


def test_rescan_noapply():
    print("rescan_noapply: skips the sweep but still selects the fabric")
    board = MockBoard(imu_a=True, imu_b=True)
    restore = install_mock(board, detection_mask=0xFF)
    try:
        r = net.rescan(None, with_chip_detect=False)
    finally:
        restore()
    check(r is not None and r["fabric"] == "acq_imu_both", "fabric not selected")
    check(r["detection"] is None, "ran detection despite noapply")
    check(board.applied_mask is None, "touched the channel mask")


def test_i2c_scan_decode():
    print("i2c_scan/eeprom_read: decode + address interpretation")
    board = MockBoard()
    board.i2c_devices[0] = [0x28] + list(range(0x50, 0x58))   # BNO055 + block-addressed
    restore = install_mock(board)
    try:
        found = net.i2c_scan(None, 'a')
        empty = net.i2c_scan(None, 'b')
        data = net.eeprom_read(None, 'a', 0x50, 0, 16, 1)
    finally:
        restore()
    check(found == [0x28] + list(range(0x50, 0x58)), f"scan found {found}")
    check(empty == [], f"port B should be empty, got {empty}")
    check(data == bytes(range(16)), f"eeprom payload {data!r}")

    # A wedged bus must report, not silently look empty.
    class Wedged(MockBoard):
        def send(self, cmd_id, param1=0, param2=0, timeout=0.5):
            if cmd_id == net.CMD_I2C_SCAN:
                return True, struct.pack('<I', 1 | (0x50 << 8)) + bytes(16) + \
                    struct.pack('<I', net.I2CSCAN_VERSION)
            return super().send(cmd_id, param1, param2, timeout)
    board = Wedged()
    restore = install_mock(board)
    try:
        check(net.i2c_scan(None, 'a') is None, "wedged bus reported as a result")
    finally:
        restore()


def test_imu_command_decode():
    print("imu commands: stream/read replies and failure statuses decode")

    class ImuBoard(MockBoard):
        """Board that streams only port A -- the acq_imu_port_a case, and the
        one that must tell the user why they got less than they asked for."""
        def __init__(self, **kw):
            super().__init__(**kw)
            self.last_mask = None
            self.last_period = None

        def send(self, cmd_id, param1=0, param2=0, timeout=0.5):
            self.commands.append((cmd_id, param1, param2))
            if cmd_id == net.CMD_IMU_STREAM:
                self.last_mask, self.last_period = param1, param2
                active = param1 & 1                     # port B has no IIC here
                period = param2 if param2 else 10
                period = max(10, min(1000, period))
                return True, struct.pack('<III', active, period,
                                         net.IMUSTREAM_VERSION)
            if cmd_id == net.CMD_IMU_READ:
                status = 0x1 | (0x0C << 8) | (0xC0 << 24)
                return True, struct.pack('<I10hBbHI', status,
                                         8192, 0, 0, 0,      # quat: w=0.5
                                         -981, 0, 0,          # accel: -9.81 m/s^2
                                         160, -160, 0,        # gyro: +10/-10 dps
                                         0xC3, 25, 0, net.IMUREAD_VERSION)
            return super().send(cmd_id, param1, param2, timeout)

    board = ImuBoard()
    restore = install_mock(board)
    try:
        r = net.imu_stream(None, 'both', 0)
        check(board.last_mask == 3, f"mask sent {board.last_mask}")
        check(r is not None and r['active'] == 1, "did not report A-only")
        check(r['period_ms'] == 10, f"period {r['period_ms']}")
        net.imu_stream(None, 'a', 50)
        check(board.last_period == 50, f"period sent {board.last_period}")
        net.imu_stream(None, 'off')
        check(board.last_mask == 0, "off did not send mask 0")
        check(net.imu_stream(None, 'bogus') is None, "accepted a bad port spec")

        s = net.imu_read(None, 'a')
        check(s is not None, "imu_read returned None")
        if s:
            check(abs(s['quat'][0] - 0.5) < 1e-9, f"quat {s['quat'][0]}")
            check(abs(s['accel'][0] + 9.81) < 1e-9, f"accel {s['accel'][0]}")
            check(abs(s['gyro'][0] - 10.0) < 1e-9, f"gyro {s['gyro'][0]}")
            check(abs(s['gyro'][1] + 10.0) < 1e-9, "negative gyro sign lost")
            check(s['calib'] == {'sys': 3, 'gyr': 0, 'acc': 0, 'mag': 3},
                  f"calib {s['calib']}")
            check(s['temp_c'] == 25, f"temp {s['temp_c']}")
    finally:
        restore()

    # A chip that answers but won't enter NDOF must not look like a sample.
    class BadImu(MockBoard):
        def send(self, cmd_id, param1=0, param2=0, timeout=0.5):
            if cmd_id == net.CMD_IMU_READ:
                status = 0x8 | (0x00 << 8)          # MODEFAIL, mode reads 0
                return True, struct.pack('<I10hBbHI', status, *([0] * 10),
                                         0, 0, 0, net.IMUREAD_VERSION)
            return super().send(cmd_id, param1, param2, timeout)
    board = BadImu()
    restore = install_mock(board)
    try:
        check(net.imu_read(None, 'a') is None, "reported a sample despite MODEFAIL")
    finally:
        restore()


def test_eeprom_failure_statuses():
    print("eeprom_read: no-ACK and short-read statuses are reported honestly")

    class NoAck(MockBoard):
        def send(self, cmd_id, param1=0, param2=0, timeout=0.5):
            if cmd_id == net.CMD_EEPROM_READ:
                return True, struct.pack('<II', 1, 0) + bytes(32) + \
                    struct.pack('<I', net.EEPROMRD_VERSION)
            return super().send(cmd_id, param1, param2, timeout)
    board = NoAck()
    restore = install_mock(board)
    try:
        check(net.eeprom_read(None, 'a', 0x50, 0, 32, 1) is None,
              "no-ACK reported as data")
    finally:
        restore()

    class Short(MockBoard):
        def send(self, cmd_id, param1=0, param2=0, timeout=0.5):
            if cmd_id == net.CMD_EEPROM_READ:
                # status 3 = short read, 4 of 32 bytes arrived
                st = 3 | (4 << 8) | (32 << 16)
                return True, struct.pack('<II', st, 4) + bytes([1, 2, 3, 4]) + \
                    bytes(28) + struct.pack('<I', net.EEPROMRD_VERSION)
            return super().send(cmd_id, param1, param2, timeout)
    board = Short()
    restore = install_mock(board)
    try:
        d = net.eeprom_read(None, 'a', 0x50, 0, 32, 1)
        check(d == bytes([1, 2, 3, 4]), f"short read returned {d!r}")
    finally:
        restore()


def test_abort_paths():
    print("abort_paths: rescan gives up cleanly when the board can't comply")

    class NoStatus(MockBoard):
        def send(self, cmd_id, param1=0, param2=0, timeout=0.5):
            if cmd_id == net.CMD_PL_STATUS:
                return False, None
            return super().send(cmd_id, param1, param2, timeout)
    board = NoStatus()
    restore = install_mock(board)
    try:
        check(net.rescan(None) is None, "did not abort without PL_STATUS")
    finally:
        restore()
    check(not any(c == net.CMD_SET_CONFIG for (c, _, _) in board.commands),
          "swapped fabrics despite an unknown board state")

    class BadConfig(MockBoard):
        def send(self, cmd_id, param1=0, param2=0, timeout=0.5):
            self.commands.append((cmd_id, param1, param2))
            if cmd_id == net.CMD_SET_CONFIG:
                return True, struct.pack('<iII', 2, 0, 0)      # PL_ERR_OPEN
            return MockBoard.send(self, cmd_id, param1, param2, timeout) \
                if cmd_id != net.CMD_SET_CONFIG else (True, None)
    board = BadConfig()
    restore = install_mock(board)
    try:
        check(net.rescan(None) is None, "did not abort on a failed fabric load")
    finally:
        restore()


def main():
    test_fabric_selection()
    test_freed_lane_correction()
    test_rescan_noapply()
    test_i2c_scan_decode()
    test_imu_command_decode()
    test_eeprom_failure_statuses()
    test_abort_paths()
    if failures:
        print(f"TB_FAIL  Errors: {failures}")
        return 1
    print("TB_PASS  Errors: 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# IMU data ingestion

Continuous BNO055 readout alongside 30 kHz acquisition: `stream_type=3`, one
52-byte datagram per fused sample per port (default 100 Hz), stamped with the
PL master timestamp so IMU samples share the neural data's clock.

Two access paths:

- **One-shot**: `CMD_IMU_READ 0xB6` / `net.py imu_read [a|b]` — blocking
  quat/accel/gyro/calib/temp read (`firmware/src-core0/pl_imu_read.c`).
  Refused while streaming. Good for bring-up and sanity checks.
- **Continuous**: `CMD_IMU_STREAM 0xB8` / `net.py imu_stream [a|b|both|off]
  [period_ms]` — the per-port state machine in
  `firmware/src-core0/pl_imu_stream.c`, packets per
  `docs/unified-packet-format.md` (IMU type 3). `net.py imu_recv` prints live
  samples; `imu_csv <file>` records; the `sink` command shows IMU packet and
  SEQ-gap counters.

## Why the stream never blocks the 30 kHz path

A fused sample is ~22 bytes of I2C: ~2.5 ms of bus time at 100 kHz — ~75
broadband sample budgets, so the pump could never wait on it. Instead each
transfer is a **combined write-then-read fed to the AXI IIC's command FIFO**
(dynamic mode, PG090): START+addr(W), register pointer, repeated START+addr(R),
then — once the core has actually taken the bus — STOP+count. That two-phase
ordering is deliberate: it is exactly what the vendor's blocking
`XIic_DynRecv` does (and what the silicon-proven detect path on this board
uses), reproduced without the blocking wait. `BUS_BUSY` does not assert on the
register write; the core has to drive a START and the address onto the wire
first, so the count is written on a later main-loop pass. The core then runs
the bus by itself; the main loop comes back once per pass and

- checks the interrupt status register once (NACK / arbitration loss),
- drains whatever the RX FIFO holds (SR empty-flag gated),

which costs a couple of AXI-Lite reads per pass while a transfer is in flight
and nothing when idle. Three bursts per tick (quat 8 B @0x20, acc 6 B @0x08,
gyr 6 B @0x14 — each far under the 16-deep RX FIFO, which `XIic_DynInit`
programs to throttle only at 16 bytes, so a burst lands whole without
mid-transfer drains), publish on the third,
and every 100th tick a 2-byte housekeeping burst (temp 0x34, calib 0x35)
refreshes the health fields in AUX1. Port B's ticks are staggered half a
period from port A's so the two ports' FIFO work interleaves.

Failure handling: NACK or arbitration loss → soft-reset the core
(`XIic_DynInit`), count it (AUX0 `iic_errors`), skip to the next tick. No
data and no error for 20 ms → same recovery (wedged-bus deadline). 16
consecutive failed ticks → the port stops itself with one console message
(an unplugged IMU must not spam an error path at 100 Hz forever). A failed
UDP send is a counted drop (AUX0 `send_drops`) and a SEQ gap — never a retry
(the next sample is 10 ms away and fresher; loss stays provable, rule 3).

## Lifecycle

- `imu_stream` **before** `start`: arming a port enters NDOF (blocking
  ~50 ms), so it is refused while neural streaming is active. Once armed, the
  stream runs concurrently with full-rate acquisition — and keeps running
  across neural `stop`/`start` (independent lifecycles).
- `set_config` auto-stops the stream (the IICs it polls vanish with the
  fabric); restart it after the swap.
- `detect_imu` / `imu_read` are refused while the stream owns a port's
  controller (both contexts share core 0 — interleaved FIFO commands would
  corrupt the transfer). `imu_stream off` first.
- A chip already in NDOF is left there on arm (fusion state + calibration
  preserved across host reconnects).

## Verification

- `firmware/test-host/run_imu_stream_test.sh` — the state machine compiled
  on the host against a register-accurate simulated IIC core + BNO055
  (`imu_host_mock.c`): cadence, packet layout, SEQ, NACK/timeout recovery,
  auto-stop, dual-port independence, fabric gating, drop accounting,
  teardown, period clamping. The mock also asserts the FIFO traffic is
  exactly the canonical combined sequence.
- `remote/test_imu_host.py` — cross-check: parses datagrams the simulated
  firmware emitted with `net.py parse_imu_packet` (field-for-field), plus a
  loopback-UDP UnifiedSink demux/fan-out/gap-accounting test.
- On hardware (needs a board + mounted IMU): see `docs/TESTING.md` /
  HANDOFF — `set_config acq_imu_both` → `imu_stream a` → `imu_recv` while
  streaming 30 kHz neural data; the acceptance gate is broadband SEQ gaps
  **still 0** with the IMU stream on.

## Deliberate scope bounds

- Fused NDOF at the BNO055's native 100 Hz. Raw AMG mode (up to 1 kHz accel)
  is a follow-up if wanted — the burst table is the only thing that changes.
- Calibration persistence (save/restore the 22-byte profile, possibly in the
  headstage EEPROM — `docs/headstage-eeprom.md`) is designed but not built:
  needs the EEPROM part confirmed first.

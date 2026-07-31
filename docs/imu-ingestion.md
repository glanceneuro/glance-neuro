# IMU data ingestion — design sketch

**Status: DRAFT (overnight 2026-07-30).** Step 1 is implemented as a stub:
`CMD_IMU_READ 0xB6` / `net.py imu_read [a|b]` — a one-shot blocking NDOF sample
(`firmware/src-core0/pl_imu_read.c`), refused while streaming. This note is the
design for the real thing: continuous readout alongside 30 kHz acquisition.

## Assumptions

1. NDOF fusion at the BNO055's native 100 Hz output rate is the target; raw
   higher-rate modes (accel alone can do 1 kHz) are out of scope until asked for.
2. The IMU stream is a **low-rate side channel**, never part of the 30 kHz
   packet path (CLAUDE.md rule 2 — nothing may add per-sample work or batching
   pressure to the neural stream).
3. Mode entry (CONFIG→NDOF, ~50 ms of usleep) may happen in the *command*
   handler (an `imu_start` command), so the polling path never sleeps.
4. BNO055 default units: quat 1/2^14, accel 0.01 m/s², gyro 1/16 °/s.

## Why the one-shot stub can't just be called in a loop

Each fused sample is a ~22-byte I2C read: at 100 kHz that is ~2.5 ms of
*blocking* polling. The core-0 main loop services lwIP and the 33 µs sample
budget; a 2.5 ms stall is ~75 missed samples and a PL FIFO overrun. So
continuous readout must be a **non-blocking state machine** clocked by main-loop
passes, exploiting the AXI IIC dynamic mode's FIFOs:

```
IDLE --(rate gate: next_due <= now)--> KICK
KICK:  enqueue in the TX FIFO: [addr+W, reg=0x20] [addr+R restart, count=8]
       (two register writes, no waiting)               --> DRAIN
DRAIN: each pass, read RX_FIFO_OCC once; pop available bytes
       (<= 9 reads/pass); when 8 bytes in hand         --> PUBLISH
PUBLISH: pack sample, bump seq, hand to the UDP path   --> IDLE
ERROR (no ACK / bus timeout via a pass counter): log once, back off 1 s --> IDLE
```

- Quaternion-only per tick (8 B) keeps every transaction under the 16-deep RX
  FIFO; accel/gyro ride on alternating ticks if wanted (quat @100 Hz, raw
  @50 Hz interleaved) rather than one 32-byte burst that outgrows the FIFO.
- Cost per main-loop pass is a couple of `Xil_In32`s only while a transfer is
  in flight — and the CLAUDE.md gotcha applies: poll `RX_FIFO_OCC` once per
  pass, not per byte-wait.
- Both ports (acq_imu_both) run the same machine on their own controller;
  their KICKs are staggered half a period apart so the DRAIN work never doubles
  up in one pass.

## Getting samples to the host

Preferred: a third UDP stream type (broadband = 0/1, LFP = 2 → **IMU = 3**),
one datagram per fused sample at 100 Hz — trivial bandwidth (~3 kB/s/port),
zero-copy on the host (`recv_into`, parse in place, same as LFP), and its own
16-bit sequence number so loss is provable (rule 3). Packet: common header
(stream_type=3, port id, seq, PL timestamp latched at PUBLISH) + the 32-byte
sample payload (same layout as `imu_sample_response_t`).

Latching `pl_get_timestamp()` at PUBLISH time stamps IMU samples on the *same
clock as the neural data*, which is the whole point of ingesting them here
rather than on the host.

Host commands: `imu_start [a|b|both]` (does the blocking NDOF entry, arms the
state machine), `imu_stop`. `net.py` grows a decoder + CSV sink; the Open Ephys
plugin can attend to stream_type 3 later (three consumers of one contract —
protocol.md must gain the packet layout when this lands).

## Open questions (Caleb)

- Is 100 Hz fused NDOF the right product, or do you want raw accel/gyro at
  higher rate (BNO055 AMG mode, up to 1 kHz accel) with fusion done offline?
- Calibration: NDOF self-calibrates continuously; do we need to persist
  calibration profiles (22 B, regs 0x55–0x6A) — possibly in the headstage
  EEPROM (docs/headstage-eeprom.md) — and restore them at imu_start?
- Should IMU streaming survive a `stop` of the neural stream (independent
  lifecycles), or stop with it?
- UDP stream_type=3 vs folding IMU words into the status snapshot: stream
  preferred per above, confirm before protocol.md changes.

## Needs hardware to validate

- The stub itself (first NDOF entry, burst-read layout, both ports).
- That DRAIN never sees a stuck transfer with clock stretching (BNO055
  stretches; the AXI IIC handles it, but the pass-counter timeout value needs
  a real measurement).
- Staggered dual-port timing under full 30 kHz streaming (netperf + seq gaps).

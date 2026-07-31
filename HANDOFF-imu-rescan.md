# IMU + rescan + EEPROM work — hardware test guide

Everything below is **implemented, built, and verified as far as it can be
without a board**. Branch `testing/rescan-drafts` (glance-neuro) and
`testing/imu-ingestion` (glance-neuro-plugin), both pushed. `blobs/` is current
with the firmware sources in the same commit. Delete this file once you've run
through it.

## What's new, in one line each

| Feature | Command | Where |
|---|---|---|
| Fabric auto-selection | `rescan [noapply]` | `net.py` |
| One-shot IMU read | `imu_read [a\|b]` | `CMD_IMU_READ 0xB6` |
| **Continuous IMU stream** | `imu_stream [a\|b\|both\|off] [ms]` + `imu_recv` / `imu_csv` | `CMD_IMU_STREAM 0xB8`, `stream_type=4` |
| I2C bus inventory | `i2c_scan [a\|b]` | `CMD_I2C_SCAN 0xB7` |
| EEPROM / device read | `eeprom_read [a\|b] [dev] [off] [len] [width]` | `CMD_EEPROM_READ 0xB9` |
| Open Ephys IMU stream | third DataStream, 10 ch/port @ 100 Hz | plugin `testing/imu-ingestion` |

## Before you touch the board (2 minutes, no hardware)

```bash
cd glance-neuro
bash firmware/test-host/run_imu_stream_test.sh   # IMU state machine
python3 remote/test_imu_host.py                  # firmware <-> net.py contract
python3 remote/test_rescan.py                    # rescan logic + I2C decoders
python3 remote/netperf_loopback.py 30 20 154 10 300   # host gate incl. IMU mix
```

All four should print `TB_PASS Errors: 0` / `net.py KEEPS UP`. If one fails
here, don't debug at the bench — the fault is in logic, not silicon.

## Flash

`cp blobs/* /path/to/SD/` (6 files: `BOOT.bin`, `acq.bin`, `detect.bin`,
`aimuboth.bin`, `aimu_a.bin`, `aimu_b.bin`). `BOOT.bin` is now ~4.5 MB because it
bakes the default `acquisition` bitstream: the FSBL configures the PL before the
network exists, so **the serial console and the MicroZed DONE LED are live from
power-on**. (The debug UART leaves the chip through PL balls, which is why a blank
PL was silent and the LED stayed unlit.) Runtime `set_config` / `rescan` swaps are
unchanged.

## Test 1 — rescan picks the right fabric (5 min)

With the IMU headstage on **port A only**:

```
python3 remote/net.py
rescan
```

Expect: `starting from fabric 'blank'` → loads `scan` → `Port A: IMU present
(BNO055, chip_id=0xA0)` / `Port B: no IMU` → loads **`acq_imu_port_a`** → phase
sweep → a final line pointing you at `imu_stream a`.

Then move the headstage to **port B** and `rescan` again → expect
**`acq_imu_port_b`**. With no headstage → **`acquisition`**.

**What to watch for:** a `correcting mask 0x..` line. That means the phase
sweep scored a freed CIPO1 lane (no LVDS pair on an IMU fabric). rescan now
removes those bits automatically, so the run is still correct — but tell me,
because it means the tied-off lane is picking up enough signal to cross
threshold and the sweep deserves a look.

## Test 2 — the IMU actually streams (the headline)

```
rescan                     # or: set_config acq_imu_both
imu_stream a               # BEFORE 'start' -- arming does a blocking NDOF entry
imu_recv 20
```

Expect 20 lines of live quaternion/accel/gyro. **Pick the headstage up and
rotate it** — quat should swing smoothly, gyro should spike while moving and
return to ~0 at rest, and accel magnitude should stay near 9.8 m/s² in any
orientation (that's the quickest sanity check that scaling is right).

`cal=` shows the four BNO055 calibration counters (sys/gyr/acc/mag, 3 = fully
calibrated). Fresh out of reset they read low; the gyro calibrates within
seconds of sitting still, the magnetometer after a figure-8 motion. Low
calibration is normal and not a bug.

Then the real acceptance test — IMU **concurrent with 30 kHz neural data**:

```
start
imu_recv 20                # still flowing while broadband streams
sink                       # broadband + LFP + IMU counters and SEQ gaps
stop
```

**The gate: `bb_seq_gaps=0` with the IMU stream running.** That is the whole
"low-rate side channel, never the 30 kHz path" claim, on hardware. `imu_seq_gaps`
should also be 0, and the per-sample `iic_errors`/`send_drops` fields (shown in
`sink` and the CSV) should stay 0.

To record: `imu_csv imu_run.csv` … `imu_csv stop`. One row per sample with the
**PL master timestamp**, so it joins to the neural stream on a common clock.

Both ports at once (needs two IMU headstages): `imu_stream both`, then confirm
`imu_recv` shows interleaved `[IMU A]`/`[IMU B]` lines with independent SEQ.

## Test 3 — the EEPROM question (this is the one I couldn't answer without you)

```
set_config scan
i2c_scan a
```

This prints an i2cdetect-style map of everything on port A's I2C bus. What it
shows decides the EEPROM question:

- **`0x28` only** → the headstage has no EEPROM on this bus; my inference in
  `docs/headstage-eeprom.md` was wrong and we look elsewhere.
- **`0x28` + one address in `0x50–0x57`** → a 24xx EEPROM, ≥32 Kbit (2-byte
  addressing). Read it: `eeprom_read a 0x50 0 32 2`.
- **`0x28` + all eight of `0x50–0x57`** → one ≤16 Kbit 24xx block-addressing
  the whole range (net.py flags this explicitly). Read with
  `eeprom_read a 0x50 0 32 1`.
- **`BUS WEDGED`** → the probe couldn't complete; tell me the address it
  stopped at.

Whatever the dump shows, send me the output and I'll write the identity-record
format against the real part. The scan is non-destructive (probe and offset
writes only move read pointers), and it is deadline-bounded, so a wedged bus
reports instead of hanging the core.

## Test 4 — Open Ephys plugin

```bash
cd glance-neuro-plugin && git checkout testing/imu-ingestion
cd Build && cmake -DGUI_BASE_DIR=/path/to/plugin-GUI .. && cmake --build . -j8
```

Put the board on `acq_imu_both` (or `acq_imu_port_a`) **before** connecting —
the plugin probes for a BNO055 at connect and only publishes the IMU stream if
one answers. Then CONNECT and start acquisition: a third stream `IMUStream`
appears with channels `IMU_A_QUAT_W … IMU_A_GYR_Z` (10 per port) at 100 Hz, in
engineering units. Rotate the headstage and watch them move in the LFP Viewer.
On stop, the console logs per-port sample and SEQ-gap counts.

Note: the plugin starts the IMU before the neural stream automatically (arming
needs the board idle). If you had started `imu_stream` from `net.py` first,
that's fine — the plugin's start is idempotent for already-running ports.

## Things that will refuse you on purpose

These are guards, not bugs — each one prints why:

- `imu_stream a` **while streaming** → refused. Arming does a ~50 ms blocking
  NDOF entry, which would blow hundreds of 33 µs sample budgets. Start the IMU
  first, or `stop` first. (Stopping the IMU is always allowed.)
- `detect_imu` / `imu_read` / `i2c_scan` **while the IMU stream owns that port**
  → refused; they'd interleave commands into a transfer in flight.
  `imu_stream off` first.
- Any IMU/I2C command on a port whose fabric has **no IIC** → refused (this is
  the mixed-fabric hang lesson: touching an absent AXI slave never returns).
- `set_config` **auto-stops** the IMU stream, since the controllers vanish with
  the fabric. Restart it after a swap.

## If something misbehaves

- **No IMU packets but `imu_stream` said it started:** check `sink` —
  `IMU=0 pkts` means nothing left the board; a nonzero `iic_errors` in
  `imu_recv` means the bus is answering badly. After 16 consecutive I2C
  failures the port auto-stops and says so on the console.
- **Broadband SEQ gaps appear only with the IMU on:** that would contradict the
  loopback measurement (188k vs 198k/s ceiling, i.e. no measurable cost) — grab
  `sink` output and the console and send it to me; that's a real finding.
- **Quaternion frozen but calib moving (or vice versa):** the housekeeping burst
  and the data bursts use the same path, so a split like that points at the
  BNO055 rather than the transport.

## Open questions only you can answer

1. The EEPROM part/address (Test 3 output answers it, or the schematic).
2. Is 100 Hz fused NDOF the right product, or do you want raw accel/gyro at up
   to 1 kHz (AMG mode)? Only the burst table changes.
3. Should the BNO055 calibration profile persist across power cycles (22 bytes,
   regs 0x55–0x6A — the headstage EEPROM is the natural home once identified)?
4. Should the IMU stream survive a neural `stop`? It does today at the firmware
   level (independent lifecycles); the plugin stops it with acquisition.

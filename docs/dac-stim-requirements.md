# DAC stimulus playback — requirements

Requirements for extending GLANCE's network control to drive the carrier's DAC70502
as a stimulus generator: uploadable arbitrary waveforms played out of PL memory,
single-shot or looping, started by software command or by a TTL input, with a
programmable output sample rate.

Status: **draft for review**. Nothing here is implemented; this document exists to
agree on scope before RTL/firmware/host work starts.

## 1. Background

### 1.1 The hardware

The GLANCE carrier (Rev 1.1) has a TI **DAC70502**: dual 14-bit buffered
voltage-output DAC with an internal 2.5 V reference, controlled by 3-wire SPI
(write-only — no MISO). Its outputs `VOUTA`/`VOUTB` drive the **DAC1/DAC2 SMA
connectors**. Full-scale range is register-selectable (GAIN/REF-DIV): 1.25 V,
2.5 V, or 5 V.

Pins (verified against the carrier schematic and the MicroZed JX1 pinout table;
identical to the reference project's constraints):

| signal | package pin | JX1 pin |
|---|---|---|
| DAC_SCLK | W18 | 74 |
| DAC_NSYNC | R18 | 70 |
| DAC_SDIN | T17 | 68 |

All bank 34 (VCCIO34 = 3.3 V, already required by the Intan interface pins there).

Datasheet limits the design must respect (TI SBAS793A):

- One SPI frame = 24 bits: `{R/W, register[6:0], data[15:0]}`; data is **MSB-aligned**
  (`{DATA[13:0], x, x}` for the 70502), so 16-bit left-aligned host samples are the
  native format and port unchanged to the 16-bit DAC80502.
- **SCLK ≤ 50 MHz — the DAC's hard SPI clock limit.** The design runs SCLK at a
  fixed 42 MHz (84 MHz engine clock ÷ 2); the rate divider (§3.3) paces *frames*
  and never changes SCLK. SYNC must rise between frames (≥160 ns high), and
  successive DAC updates must be **≥1 µs apart** (`t_DACWAIT`). Net ceiling
  ≈ 600 kframes/s.
- Output settling ~5 µs to ±2 LSB, slew 2 V/µs — useful analog bandwidth is in the
  tens of kHz; the chosen 240 kframes/s master rate (§3.3) has a 4.17 µs frame
  period sitting just under the settling time, and divided rates are slower still.
- The SPI interface is **write-only**: no readback, no CRC, and the REF-ALARM fault
  bit is unreachable. The system can verify what it *sent*, never what the chip
  *holds*. Integrity must therefore be enforced on the host→PL upload path.
- On-chip features worth using: per-channel power-down — the output is disconnected
  from the buffer and tied to AGND through 1 kΩ. **There is no true high-impedance
  output state**; power-down is the closest the chip gets, and with the single-sided
  supply it parks the output passively at 0 V. Also BRDCAST (one frame writes both
  channels), synchronous mode + LDAC trigger frame (buffer A and B, update both
  simultaneously), soft reset (TRIGGER = 0x0A).
- Power-on state: the carrier ties RSTSEL (and SPI2C) to GND at U5 (verified in
  `glance-neuro-hardware/JX1_connections.kicad_sch`), so the DAC powers up in SPI
  mode driving **zero-scale (0 V)** until firmware writes power-down — the benign
  case.

### 1.2 The reference design (`spi_dac_70502`)

The sibling repo `spi_dac_70502` (reference only — we do not modify it) proves the
playback concept on this exact carrier: an AXI-Lite peripheral holding a **frame
RAM** (16384 × 24-bit SPI frames stored one per 32-bit word) and an index-walking
engine that plays `START_INDEX → END_INDEX` once, then loops
`LOOP_INDEX → END_INDEX`, in continuous or fixed-frame-count mode, with graceful
stop, soft reset, sticky error status, and a completed-frame counter. Start/stop are
CDC-safe toggle pulses from the AXI domain into the 84 MHz SPI engine clock — the
same two clocks GLANCE already uses, and the natural join point for a hardware
trigger. Init frames (GAIN, SYNC, etc.) are simply the first RAM entries before the
loop region, sent once.

What it lacks for our purposes: frame pacing (`CS_HIGH_CLKS`) is a **compile-time
parameter** (no runtime rate divider); there is no hardware trigger input; no loop
counter (only total-frame count); no defined safe-output behaviour on stop; no
network API; and its TTL debug mirror uses pins W16/V16/W20 which are
`digital_in_0[0..2]` on GLANCE — the mirror must be dropped at integration.

### 1.3 What GLANCE already provides

- **Control path**: 20-byte fixed TCP command frames (`0xDEADBEEF` magic) dispatched
  in `firmware/src-core0/network.c`; opcodes ≤ 0x91 are in use. Commands map to
  typed `pl_*` helpers doing AXI-Lite accesses.
- **Digital inputs**: `digital_in_0[7:0]` (PMOD, 3.3 V, pulldowns) already enter the
  PL, are latched into every packet header (AUX1 word, bits [7:0]), and drive the
  aux GPIO overrides. This is the trigger surface.
- **CDC-safe upload idioms**: payload-register + toggle-strobe (aux program banks,
  LFP coefficients), including a double-buffered bank swap with confirm.
- **Clocks**: 131.25 MHz AXI ↔ 84 MHz data path, declared asynchronous. The
  reference design's SPI engine also runs at 84 MHz — the stim engine slots into the
  existing 84 MHz domain and shares its reset (`proc_sys_reset_0_84M`).

## 2. Definitions

- **Frame**: one 24-bit SPI transaction (one DAC register write). Stored as one
  32-bit word.
- **Sample**: one output value on one DAC channel. Stereo playback interleaves A and
  B frames (2 frames/sample-pair) or, in synchronous mode, buffers A, B, then an
  LDAC trigger frame (3 frames/pair, both outputs step together).
- **Master rate / divider k**: the engine issues frames at a fixed **master rate of
  240 kframes/s** (= 84 MHz / 350 exactly) divided by a runtime integer **k**, so
  frame rate = 240/k kf/s. (The reference design's compile-time pacing was
  ≈ 32.76 kf/s; we replace it — see §3.3.)
- **Stimulus**: a contiguous frame-RAM region `[START_INDEX .. END_INDEX]` with a
  loop-back point `LOOP_INDEX`.

## 3. Functional requirements

### 3.1 Stimulus storage and upload

- **R1** — The PL shall hold stimuli in a dedicated frame RAM of **16,384 frames**
  (16 BRAM36 — a deliberate cap; see §4), independent of the acquisition BRAMs.
  Longer stimuli come from the rate divider (§3.3), not from more BRAM.
- **R2** — The host shall upload arbitrary frame data over the existing TCP control
  channel, addressed by frame index, with a full 16 K-frame (64 KB) RAM uploading
  in ≤ ~2 s. Mechanism and trade-offs in §3.9.
- **R3** — Upload integrity shall be provable: the host can retrieve a CRC32 (or
  readback) of any frame-index range and compare against the local copy. Because the
  DAC itself is write-only (§1.1), this is the *only* integrity gate — it is
  mandatory, not optional.
- **R4** — Two independent upload interlocks, one per hazard:
  - **PL**: frame-RAM writes while *playback* is running are rejected and set a
    sticky error (reference-design behaviour);
  - **firmware (v1)**: upload and verify commands (`STIM_UPLOAD_BEGIN`,
    `STIM_WRITE`, `STIM_VERIFY`) are rejected with an error ack while
    *acquisition* is streaming.

  Playback control, triggering, and configuration commands remain available
  during acquisition — stimulating while recording is the point; only waveform
  *changes* wait for a streaming pause. Upload-during-streaming and live waveform
  swap are follow-on features (§8).
- **R5** — Frame RAM contents persist across playback start/stop and are only lost
  on power cycle / reconfiguration. The host library shall not assume persistence
  across board reboot.

### 3.2 Playback modes

- **R6** — **Single trigger**: play the stimulus once (`START → END`), then stop.
  (Implemented as fixed-frame-count mode with count = window length.)
- **R7** — **N-loop**: play the first pass then loop `LOOP → END` until a total of
  N loops have completed, then stop. N up to 2³²−1 frames total is sufficient
  (host computes frame count = pass + N·loop length; ≥ 36 h at full rate).
- **R8** — **Continuous**: loop until stopped. First pass starts at `START_INDEX`
  so one-time init/config frames can precede the loop region.
- **R9** — **Stop** completes the in-flight frame (never truncates an SPI frame),
  then performs the safe-output sequence (R19).
- **R10** — Loop length is limited only by the RAM window (`LOOP..END`), down to a
  minimum of 2 frames; the engine tracks and reports the current index and completed
  frame count (64-bit).

### 3.3 Sample-rate divider

- **R11** — Frame pacing shall be runtime-programmable as a **fixed master rate
  with an integer divider**: frames issue at 240 kframes/s (frame period base =
  350 clocks at 84 MHz, exact) divided by runtime integer **k**, i.e. the PL frame
  period is 350·k clocks and frame rate = 240/k kf/s. This replaces the
  compile-time `CS_HIGH_CLKS`. The master was chosen for its divisor lattice —
  240 k = 2⁴·3·5 k — so every mode lands on round sample rates (§3.8) and on an
  exact integer relationship to the 30 kHz acquisition rate, which derives from
  the same 84 MHz clock (mono 30 kS/s at k = 8; interleaved 30 kS/s/ch at k = 4).
- **R12** — Divider range: k = 1 to 2³²−1 (k = 0 rejected). At k = 1 the 4.17 µs
  frame period already clears the datasheet floor of ~1.6 µs (fixed 42 MHz SCLK:
  24 bits ≈ 0.57 µs, plus SYNC-high and `t_DACWAIT`) by 2.7×, so **every k is
  timing-legal by construction** — no clamp logic needed. Large k covers slow
  envelopes without host involvement (k_max ≈ 5 h/frame). Stored-stimulus duration
  scales linearly with k (§4). The divider paces frames only; SCLK never changes.
- **R13** — The stimulus clock derives from the same 84 MHz clock as acquisition, so
  stimulus and recording cannot drift. Changing k while running takes effect at
  the next frame boundary (or is latched at start — implementer's choice, but the
  behaviour must be documented).

### 3.4 Triggering

- **R14** — Software commands: `START` (with mode per §3.2), `TRIGGER`
  (arm-independent immediate single-shot), `STOP`. Hardware and software paths are
  equivalent in effect.
- **R15** — **Hardware trigger**: any one of `digital_in_0[7:0]`,
  register-selected (3-bit line select), with selectable polarity, in one of two
  modes:
  - **edge-trigger**: active edge starts a single-shot pass (R6) — or an N-loop run
    if so configured;
  - **gate**: active level runs the loop continuously; inactive level performs a
    graceful stop.

  Arming and hardware triggering are PL-resident: once configured they function
  with no host connected (R21).
- **R16** — Trigger inputs are 2-FF synchronized into the 84 MHz domain and pass a
  programmable minimum-pulse-width filter (glitch reject, default ~1 µs).
- **R17** — Retrigger policy while running is configurable: ignore (default) or
  restart from `START_INDEX`.
- **R18** — Every trigger/start/stop event shall be timestampable against the
  acquisition stream: the PL latches the current acquisition timestamp at the most
  recent start and stop into status registers, and the raw trigger line is already
  visible per-packet in the header AUX1 breadcrumb. (Arming state and running state
  are host-pollable via status.)

### 3.5 Output safety

Stimulation electrodes are attached to tissue; undefined output voltage is a fault.

- **R19** — After any stop (software, gate-low, N-loop completion, finite-count
  completion), the outputs shall enter the **configured idle state**,
  register-settable via `STIM_SET_IDLE`:
  - **power-down (default)** — output passively tied to AGND through the internal
    1 kΩ; the closest available approximation of Hi-Z (§1.1);
  - **driven idle codes** — per-channel 14-bit codes actively driven (default
    zero-scale, 0 V), for applications needing a defined low-impedance level.

  `STIM_ZERO` forces the configured idle state immediately from any state;
  `STIM_POWERDOWN` forces power-down regardless of the configured mode.
- **R20** — The firmware shall configure the DAC's GAIN/SYNC/CONFIG registers at
  init to a known state and expose the chosen full-scale range to the host, so
  volts↔code conversion is unambiguous. Host tools express amplitudes in volts.
- **R21** — **Playback is autonomous.** Once configured and started (or armed for a
  hardware trigger), the stimulus engine runs entirely in the PL: it shall not
  depend on the TCP connection, the host, or firmware attention. Control-connection
  loss, host exit, or a busy firmware loop must not pause, stop, or glitch
  playback; the host can reconnect later and read status. Playback ends only on:
  stop command, gate deassertion, loop/count completion, STIM_ZERO / power-down,
  or power loss.
- **R22** — The DAC has no true Hi-Z state; **power-down (output → AGND through
  1 kΩ) is the bring-up and reset state** (and the default idle state, R19). The
  only unavoidable driven-level window is between power-on and firmware init,
  where the chip drives the RSTSEL-selected level — zero-scale, 0 V, on this
  carrier (§1.1) — so the output never presents an uncontrolled non-zero voltage. At boot/reset the firmware soft-resets
  the DAC (TRIGGER = 0x0A) and immediately writes CONFIG power-down; the outputs
  stay parked there until the first playback start (whose init frames restore
  active mode). A dedicated `STIM_POWERDOWN` command re-enters this state at any
  time. Playback never auto-resumes after reboot.

### 3.6 Non-interference with acquisition (hard constraints)

- **R23** — The stimulus subsystem shall not perturb the acquisition path: no change
  to the one-datagram-per-sample contract, no added latency or loss on the 30 kHz /
  3 kHz streams, sequence-gap-free runs with stimulation active.
- **R24** — No sharing of the CDMA engine or the acquisition BRAMs. Firmware
  interaction with the stim engine on the hot path is bounded (status polled only on
  demand; every `Xil_In32` stalls the core — poll nothing per-sample).
- **R25** — Timing closure with the existing design: the stim engine lives in the
  84 MHz domain, is reset from `proc_sys_reset_0_84M`, and adds no new
  cross-domain single-cycle paths (CDC via the established toggle/2-FF idioms).

### 3.7 Network API and host library

- **R26** — New TCP commands in a reserved **0xA0–0xAF** block (current opcodes end
  at 0x91), same 20-byte frame + ack discipline. Working allocation:

  | cmd | name | params (p1, p2) |
  |---:|---|---|
  | 0xA0 | STIM_SET_WINDOW | start_index, end_index |
  | 0xA1 | STIM_SET_LOOP | loop_index, loop_count (0 = infinite) |
  | 0xA2 | STIM_SET_RATE | divider k (frame rate = 240 kf/s / k) |
  | 0xA3 | STIM_SET_TRIGGER | line \| pol<<3 \| mode<<4 \| retrig<<6, min_pulse_µs |
  | 0xA4 | STIM_START | mode (single / n-loop / continuous) |
  | 0xA5 | STIM_STOP | — |
  | 0xA6 | STIM_TRIGGER | — (software single-shot) |
  | 0xA7 | STIM_ZERO | — (force idle code now) |
  | 0xA8 | STIM_UPLOAD_BEGIN | start_index, — (resets the write pointer) |
  | 0xA9 | STIM_WRITE | frame[i], frame[i+1] (pointer auto-increments by 2) |
  | 0xAA | STIM_VERIFY | offset, count → replies CRC32 of the range |
  | 0xAB | STIM_GET_STATUS | — → stim status struct |
  | 0xAC | STIM_SET_IDLE | mode (0 = power-down, default; 1 = drive codes), codeA<<16 \| codeB |
  | 0xAD | STIM_POWERDOWN | — (outputs → 1 kΩ to AGND, R22) |

  Upload stays inside the fixed 20-byte framing — see §3.9 for the alternatives
  considered and the measured-fallback plan.
- **R27** — `STIM_GET_STATUS` returns its **own** response struct (running, armed,
  mode, current index, completed count, loop count, start/stop timestamps, sticky
  errors, config echo). The existing `status_response_t` and its `_Static_assert`
  size are untouched, so the v2 contract does not break and old hosts interoperate.
- **R28** — `remote/net.py` grows matching commands plus conveniences: upload from a
  NumPy array (volts or raw codes; mono/stereo; interleaved or LDAC-synchronous
  frame construction with init frames prepended), a Gaussian-pulse generator, and a
  round-trip verify. Zero-copy rules apply only to the data hot path; upload is
  cold-path Python.
- **R29** — Docs move together: `docs/protocol.md`, `docs/register-map.md` (or a new
  `docs/stim.md`), `firmware/include/main.h`, `net.py`. The Open Ephys plugin is a
  data consumer and is unaffected by v1 (no packet-format change); plugin-side stim
  UI is out of scope (§8).

### 3.8 Stereo semantics (host-library convention, not PL logic)

Because the RAM stores raw SPI frames, channel modes are **upload conventions**, not
engine features — the PL just plays frames at the divided master rate (§3.3):

- mono (A or B; likewise BRDCAST for both-channels-same-waveform): one frame per
  sample; sample rate = 240/k kS/s;
- stereo interleaved: `A,B,A,B…`; per-channel rate = 120/k kS/s; B lags A by one
  frame period (k × 4.17 µs);
- stereo synchronous: `A,B,LDAC` triplets (SYNC register put in synchronous mode by
  init frames); per-channel rate = 80/k kS/s; A and B step simultaneously.

Round sample rates land on integer k in every mode:

| mode | rate | 30 kS/s at | round rates (kS/s) |
|---|---|---|---|
| mono / BRDCAST | 240/k | k = 8 | 240, 120, 80, 60, 48, 40, 24, 20, 16, 15, 12, 10, 8, 6, 5, 4, 3, 2, 1 |
| stereo interleaved | 120/k per ch | k = 4 | 120, 60, 40, 24, 20, 15, 12, 10, 8, 6, 5, 4, 3, 2, 1 |
| stereo synchronous | 80/k per ch | — | 80, 40, 20, 16, 10, 8, 5, 4, 2, 1 |

Synchronous mode cannot hit 30 kS/s exactly (80/k ≠ 30 for any integer k; nearest
are 20 and 40). Interleaved at k = 4 is the 30 k stereo answer; its fixed 16.7 µs
A→B skew (half a 30 kHz sample period) is a known constant the host library can
pre-compensate when it builds the B-channel waveform.

The host library implements all three; the requirements above are mode-agnostic.

### 3.9 Upload mechanism — options and recommendation

Three candidate mechanisms were considered for moving stimulus data host → PL:

1. **Chunked fixed-frame commands (recommended).** `STIM_UPLOAD_BEGIN(start)`
   resets a firmware-held write pointer, then each `STIM_WRITE` carries two frames
   in param1/param2 and auto-increments the pointer — the same auto-increment
   idiom the LFP coefficient upload already uses. A full 16,384-frame RAM is
   8,192 commands ≈ 160 KB on the wire. The host pipelines commands without
   waiting on individual acks (TCP guarantees ordering; `ack_id` matching catches
   any miss) and finishes with `STIM_VERIFY`, which must equal the host-computed
   CRC32 before playback is allowed. Firmware cost per command is two register
   writes, and because v1 gates uploads to acquisition-idle periods (R4) the main
   loop can burst-process whole TCP segments of commands (~73 per segment) with
   no sample budget to respect — a full upload lands well inside R2's ≤ 2 s.
   *Pros*: zero change to the 20-byte framing or the alignment-safe RX reassembly
   state machine; per-chunk acks; trivially resumable after any failure.
   *Cons*: ~60% wire overhead and per-command dispatch cost — acceptable at this
   RAM size.

2. **Binary-payload mode.** A `STIM_UPLOAD(offset, count)` command switches the
   TCP receiver into a raw sink for count×4 bytes, then acks with a CRC.
   Efficient, but it adds a second state to the command reassembly in
   `tcp_recv_cb`, and a connection drop mid-payload leaves the parser needing a
   timeout/resync path. Real protocol risk for a once-per-stimulus operation.

3. **Separate bulk-upload TCP port.** Keeps the control protocol pure, but adds a
   listener, a port, and documentation surface for the same sink logic as (2).

Shrinking the frame RAM to 16 K frames (§4) decides this: at 64 KB total,
option 1 sits comfortably inside R2's ≤ 2 s budget (8,192 pipelined commands at
even a conservative 10 k cmds/s ≈ 0.8 s), so the protocol surgery of (2)/(3)
buys nothing we need. **Requirement: implement option 1 and measure upload time
in V2. Only if the measurement misses R2 does option 2 get designed — with an
explicit desync/timeout story — as a follow-on change.**

## 4. Memory budget — how long can a stimulus be?

Device: XC7Z020 — **140 BRAM36 tiles** total. Measured from a clean rebuild of
current source (2026-07-27, LFP output BRAM included): **53.5 tiles used
(48 RAMB36 + 11 RAMB18, 38%) — ~86 tiles free**. LUTs at 26%, and all 220
DSP48s free — BRAM is the only budget that matters here. These are measured
numbers from a placed utilization report, not source-derived estimates; re-check
them after any change that adds memories.

Frame storage is one 32-bit word per 24-bit frame → 1024 frames per BRAM36.

BRAM belongs to acquisition first: the stimulus RAM is deliberately capped at
**16 BRAM36 (11% of the device) = 16,384 frames** — the reference design's default
depth, ported unchanged. Long stimuli come from the rate divider, not from BRAM.

Loop duration = frames × k / 240 kf/s, i.e. 68.3 ms × k for a full 16 K RAM:

| allocation | BRAM36 (of 140) | frames | k=1 (240 kf/s) | k=8 (mono 30 kS/s) | k=240 (1 kS/s) | k=2400 (100 S/s) |
|---|---|---|---|---|---|---|
| floor | 8 (6%) | 8,192 | 34 ms | 0.27 s | 8.2 s | 82 s |
| **cap (chosen)** | **16 (11%)** | **16,384** | **68 ms** | **0.55 s** | **16.4 s** | **164 s** |

Durations are wall-clock loop lengths and are mode-agnostic (stereo halves the
per-channel sample count, not the duration). At 16 tiles, ~70 tiles (~50% of the
device) remain free after the acquisition BRAMs. For scale: a 5 ms Gaussian pulse
at mono 30 kS/s is 150 frames — under 1% of the RAM (1,200 frames / 7% at the
full master rate). A stimulus that overflows the RAM at the desired rate is the
cue to raise k, or the use case for DDR playback (below).

If frames were packed as 16-bit samples with PL-synthesized command bytes, capacity
doubles — deliberately **not** in v1, because storing raw frames keeps init
sequences, LDAC triplets, and any future DAC register use expressible with zero
engine changes.

Beyond BRAM: truly long stimuli (minutes–hours at high rates) need DDR-backed
playback — 256 MB of the 1 GB PS DDR holds 67 M frames (~4.7 min at the 240 kf/s
master, ~37 min at mono 30 kS/s, hours at larger k). That requires a PL fetch path (ping-pong BRAM pages refilled by DMA)
and must not contend with the acquisition CDMA on the 33 µs budget. Phase 2 (§8);
the v1 register map shall not preclude it (indices already 32-bit-clean).

## 5. Architecture notes (informative)

The stimulus engine is a new self-contained AXI-Lite peripheral in the 84 MHz
domain, following the repo's CDC and reset conventions (reset from
`proc_sys_reset_0_84M`; toggle/2-FF crossings). Whether it reuses reference-design
RTL or is written fresh is an implementation choice these requirements
deliberately do not make. What **shall** carry over from the reference project is
its bench-validated hardware facts:

- **Pin constraints**: W18 (SCLK), R18 (SYNC_N), T17 (SDIN) — LVCMOS33, bank 34 —
  tested on this carrier against this DAC. Do **not** carry the reference's debug
  SPI mirror pins (W16/V16/W20): they collide with `digital_in_0[0..2]`.
- **SPI electrical timing**: mode 1 (CPOL = 0, CPHA = 1) at 42 MHz (84 MHz ÷ 2),
  CS_SETUP = 2 and CS_HOLD = 1 engine clocks — scope-verified.
- **Playback semantics** (§3.2: START/LOOP/END, graceful stop, sticky errors) are
  what the reference implements; its RTL can serve as an executable cross-check
  in simulation.

Blocks the implementation must provide, however built:

1. **Frame-tick pacing**: fixed 240 kf/s master ÷ integer k (R11–R13), i.e. frame
   period = 350·k clocks at 84 MHz, k ≥ 1.
2. **Trigger block**: `digital_in_0` tap → sync/filter → line/polarity/mode mux →
   start/stop pulses merged with the software start/stop path (R14–R17).
3. **Timestamp latches** on start/stop from the acquisition timestamp counter (R18).
4. **Idle-state sequencer** for the stop path, STIM_ZERO, and power-down (R19/R22).
5. **Frame RAM**: 16,384 × 24-bit frames (one per 32-bit word), 128 K AXI aperture,
   memory-mapped readback for R3.
6. New AXI-Lite base for the peripheral (registers + frame-RAM window in one
   aperture). This needs a SmartConnect `NUM_MI` bump and an `assign_bd_address`
   in the block design — both masters are currently fully populated. Alternative
   (no BD change): fold registers into the existing `axi_lite_registers` bank and
   upload via the toggle-strobe idiom — workable, but forfeits memory-mapped
   readback (R3) and pushes ~16 K strobed writes through the hot control path, so
   the dedicated aperture is preferred.

Firmware: `pl_stim.c` with typed helpers mirroring the `pl_*` conventions; command
dispatch additions in `network.c`; upload sink for STIM_UPLOAD. All cold-path.

## 6. Verification requirements

- **V1** — RTL testbench for the engine: single/N-loop/continuous, stop mid-loop,
  divider extremes, trigger edge/gate/retrigger, idle-code sequence, RAM-write-
  while-running rejection.
- **V2** — Loopback-style host test: upload → CRC verify → playback status
  observation, in `net.py` self-test style.
- **V3** — Bench test with scope on DAC1/DAC2: Gaussian pulse fidelity, loop
  seam continuity, trigger-to-output latency (spec: < 2 frame periods), divider
  accuracy.
- **V4** — Regression: full-rate 256-channel + LFP streaming with continuous
  stimulation running — zero sequence gaps (R23), timing closure met, and
  `netperf_loopback.py` unchanged on the host gate.
- **V5** — `scripts/build.sh` remains the only build entry point; the stim RTL and
  BOOT.bin ship in the same commit per repo hard rules.

## 7. Open questions

None — all first-draft questions are resolved and folded into the requirements:

- **RSTSEL strap (was Q1)**: verified in the carrier schematic — U5's RSTSEL and
  SPI2C pins share a GND tie (`JX1_connections.kicad_sch`), so the pre-firmware
  power-on window drives zero-scale (0 V) and the interface is permanently SPI.
  With R22's immediate power-down at init, the output never presents an
  uncontrolled non-zero level.
- Stimulus RAM capped at 16 BRAM36 (§4); master rate fixed at 240 kf/s with
  integer divider k (§3.3); playback is host/TCP-independent (R21); no true Hi-Z
  exists, so power-down-to-GND is the default idle and bring-up state, with
  driven idle codes register-selectable (R19/R22); the PMOD is the accepted
  trigger surface (R15); upload stays inside fixed-frame commands (§3.9) and v1
  rejects uploads while acquisition streams (R4).

Remaining implementer-documented choices: R13 (divider change mid-run: next
frame boundary vs latched at start) and the §3.9 upload-time measurement in V2.

## 8. Out of scope for v1 (phase 2 candidates)

- DDR-backed playback for minutes-to-hours stimuli (ping-pong page refill; must not
  touch the acquisition CDMA budget).
- Upload while acquisition streams (throttled trickle, a few commands per
  main-loop pass) — v1 rejects uploads during streaming (R4).
- Live waveform swap during playback (double-buffered banks, aux-engine style).
- Closed-loop stimulation (host- or PL-triggered from neural data) — the edge-trigger
  path (R15) plus host software already enables a slow software loop; hard-real-time
  closed loop is its own project.
- The two ADS7029 ADCs on the carrier (stimulus readback / monitoring).
- Open Ephys plugin stimulation UI.

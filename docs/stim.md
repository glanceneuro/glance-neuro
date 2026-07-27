# DAC stimulus playback — implementation reference

The stimulus subsystem plays 24-bit DAC70502 SPI frames out of a 16,384-frame
PL RAM at a fixed 240 kframes/s master rate divided by an integer k. Design
requirements and rationale live in `dac-stim-requirements.md`; this file is the
as-built contract: PL registers, TCP commands, and the upload procedure.

Three consumers, one contract: `programmable_logic/src/stim_axi_regs.sv` (the
hardware), `firmware/include/pl_stim.h` + `firmware/src-core0/pl_stim.c` (the
driver + TCP dispatch in `network.c`), and `remote/net.py` (`CMD_STIM_*`,
`stim_*` helpers). Change one, change all three plus this file.

## Hardware shape

`stim_top` (block-design module reference) = `stim_axi_regs` (AXI-Lite,
131.25 MHz) + `stim_frame_ram` (16384 x 32, true dual port across the clock
pair) + `stim_engine` + `stim_spi_shifter` (both 84 MHz, reset from
`proc_sys_reset_0_84M`). DAC pins: SCLK W18, SYNC_N R18, SDIN T17 (bank 34,
LVCMOS33). SCLK is fixed at 42 MHz (84/2), SPI mode 1, CS_SETUP=2, CS_HOLD=1 —
the timing bench-verified by the `spi_dac_70502` reference project.

The engine consumes `digital_in_0[7:0]` (trigger source) and the acquisition
`master_timestamp` (start/stop latching) — both already in the 84 MHz domain,
no CDC. Frame pacing: one frame per 350·k clocks; k=1 (4.17 µs) already clears
the DAC's ~1.6 µs floor, so every k ≥ 1 is legal by construction.

## AXI-Lite aperture — base `0x43C00000`, 128K

`0x00000..0x00048` registers; `0x10000 + 4·i` = frame RAM word *i* (RW; reads
back for CRC verification).

| off | reg | access | content |
|---:|---|---|---|
| 0x00 | CONTROL | W1P | [0] start [1] stop [2] soft_reset [3] clear_sticky [4] force_zero [5] force_powerdown [6] dac_soft_reset |
| 0x04 | STATUS | RO | [0] running [1] shifter_busy [2] armed [3] cfg_valid [4] sticky_ram_write [5] sticky_bad_start [6] idle_seq_active [15:8] digital_in |
| 0x08 | MODE | RW | [0] continuous [1] hw_arm [3:2] trig_mode (0 off, 1 edge, 2 gate) [4] trig_pol [7:5] trig_line [8] retrig_restart [9] idle_drive_codes |
| 0x0C | RATE_K | RW | divider k ≥ 1 (frame rate = 240 kf/s / k), latched at start |
| 0x10 | START_INDEX | RW | first frame of the first pass |
| 0x14 | END_INDEX | RW | inclusive last frame |
| 0x18 | LOOP_INDEX | RW | wrap target after END_INDEX |
| 0x1C | FRAME_COUNT | RW | total frames in finite mode (ignored continuous) |
| 0x20 | IDLE_CODES | RW | {codeB[15:0], codeA[15:0]}, MSB-aligned |
| 0x24 | TRIG_MINPULSE | RW | trigger glitch filter, 84 MHz clocks |
| 0x28 | CURRENT_INDEX | RO | |
| 0x2C/0x30 | COMPLETED LO/HI | RO | frames sent this run (zeroed at start) |
| 0x34/0x38 | TS_START LO/HI | RO | acquisition timestamp at (re)start |
| 0x3C/0x40 | TS_STOP LO/HI | RO | acquisition timestamp when fully idle |
| 0x44 | RAM_DEPTH | RO | 16384 |
| 0x48 | VERSION | RO | 0x53540100 |

Semantics worth knowing (details in `stim_engine.sv`):

- **Config is latched at start** (R13 decision): mid-run writes to MODE/RATE_K/
  indices take effect at the next start, not immediately. Trigger-conditioning
  fields (line/pol/minpulse) act live.
- Every stop path (stop, gate-low, count-complete, zero, powerdown) drains the
  in-flight frame, then emits the idle sequence — power-down (CONFIG 0x030003)
  or driven idle codes per MODE[9] — with a full master period of spacing at
  the seam so `t_DACWAIT` holds; `running` clears at drain, `TS_STOP` latches
  when the idle sequence finishes.
- From idle, force_zero / force_powerdown / dac_soft_reset emit maintenance
  frames without touching run bookkeeping.
- RAM writes while running are blocked and set sticky STATUS[4]; a start with
  invalid config (k=0, start>end, loop>end, finite count 0) is refused with
  sticky STATUS[5].
- Multi-word status (COMPLETED, TS_*, CURRENT) crosses domains as plain 2-FF
  words: read them when the state they describe is settled. `running` clears
  at the stop *drain*, but TS_STOP latches only when the idle sequence
  finishes — so the settled condition is **running==0 AND idle_seq_active==0**
  (STATUS bits 0 and 6), not running alone. While running, accept
  debug-grade skew.
- Write **one one-shot CONTROL bit per AXI write.** The W1P bits cross the
  clock domain as independent toggles, so two bits written together can
  arrive a cycle apart and race each other's side effects (the firmware
  driver already obeys this).
- The engine only accepts start/maintenance pulses from its idle state; a
  pulse landing during the drain/idle-sequence window is discarded. The
  firmware driver waits for full idle before start, and issues the safe-state
  commands with a settle-and-confirm retry, so an acked command has taken
  effect.

## TCP commands (0xA0 block)

Same 20-byte frame + ack discipline as every other command
(`docs/protocol.md`). `p1`/`p2` = param1/param2.

| cmd | name | params |
|---:|---|---|
| 0xA0 | STIM_SET_WINDOW | p1 start_index, p2 end_index |
| 0xA1 | STIM_SET_LOOP | p1 loop_index, p2 frame_count (finite total; 0 with continuous) |
| 0xA2 | STIM_SET_RATE | p1 = k (≥1) |
| 0xA3 | STIM_SET_TRIGGER | p1 = line \| pol<<3 \| mode<<4 \| retrig<<6 \| arm<<7; p2 = min_pulse_µs |
| 0xA4 | STIM_START | p1 = 0 finite / 1 continuous |
| 0xA5 | STIM_STOP | — |
| 0xA6 | STIM_TRIGGER | — software single-shot (forces finite) |
| 0xA7 | STIM_ZERO | — disarms hw trigger, then configured idle state |
| 0xA8 | STIM_UPLOAD_BEGIN | p1 = start_index, p2 = total word count |
| 0xA9 | STIM_WRITE | p1/p2 = two frame words, auto-increment (final odd word: p2 is padding) |
| 0xAA | STIM_VERIFY | p1 = offset, p2 = count → 4-byte CRC32 reply |
| 0xAB | STIM_GET_STATUS | — → 68-byte struct (`pl_stim.h` / net.py `STIM_STATUS_FORMAT` `<8I3Q3I`) |
| 0xAC | STIM_SET_IDLE | p1 = 1 drive codes / 0 power-down; p2 = codeB<<16 \| codeA |
| 0xAD | STIM_POWERDOWN | — disarms hw trigger, outputs → 1 kΩ to AGND |

**Safety composition:** STIM_ZERO and STIM_POWERDOWN clear MODE.hw_arm before
acting — otherwise a gate held active would restart playback the moment the
safe state was reached.

**v1 upload gate:** STIM_UPLOAD_BEGIN / STIM_WRITE / STIM_VERIFY return
ACK_ERROR while acquisition streams (`pl_is_transmission_active()`), and
BEGIN is also refused while playback runs. Playback control, triggering, and
config commands work during acquisition — stimulating while recording is the
point.

## Upload procedure (what net.py `stim_upload` does)

1. `STIM_UPLOAD_BEGIN(start, count)` — arms a firmware write pointer.
2. `count/2` × `STIM_WRITE` — pipelined: send all commands without waiting,
   then drain the 3-byte acks in order and match `ack_id`s (TCP ordering makes
   any mismatch a real fault). No per-command UART logging on this path.
3. `STIM_VERIFY(start, count)` — firmware CRC32s the RAM by readback; must
   equal the host's `zlib.crc32` over the little-endian words. Playback of an
   unverified upload is a host-side protocol violation.

## Channel modes (host conventions — the PL just plays frames)

| mode | frames/sample | per-ch rate | net.py builder |
|---|---|---|---|
| mono A or B / BRDCAST | 1 | 240k/k | `stim_frames_mono` |
| stereo interleaved | 2 | 120k/k (B lags one frame) | `stim_frames_interleaved` |
| stereo synchronous (LDAC) | 3 | 80k/k, simultaneous | `stim_frames_ldac` |

Builders prepend two init frames — CONFIG (exit power-down) and GAIN 0x0103
(REF-DIV=1, gain 2 → 2.5 V full-scale; the power-on default is 5 V full-scale,
which breaks the volts↔code math and trips REF-ALARM at VDD = 3.3 V); the LDAC
builder also prepends the SYNC-mode arm frame. `stim_play` points LOOP_INDEX past these
init frames so a looping stimulus replays only the samples. 30 kS/s lands at
k=8 mono, k=4 interleaved; LDAC mode cannot hit 30 k exactly (nearest 20/40).

## Boot state

`pl_stim_boot_init()` (called from core-0 init): engine soft-reset → DAC
soft-reset frame (TRIGGER=0x0A) → 300 µs (DAC POR takes 250 µs) → CONFIG
power-down. Outputs sit at 1 kΩ-to-AGND until the first playback. The carrier
straps RSTSEL=GND, so even the pre-firmware window drives 0 V.

## Known limitations / deferred hardening

Reviewed and consciously deferred (none block v1; all are engine-RTL changes
that warrant their own tested commit):

- A hardware retrigger edge landing in the engine's 2-cycle RAM-read pipeline
  is dropped (~0.6% of async edges at k=1); and the retrigger reload samples
  the live FRAME_COUNT rather than the start-latched copy, so rewriting
  config mid-run while retriggering can tear. Rule until fixed: treat all
  config as frozen while running (which is the documented contract anyway).
- Register decode ignores address bits [15:7], so undefined offsets in the
  low 64K alias onto the register file without SLVERR — drivers must stay
  inside the documented map.
- The master rate (240 kf/s) and the 84 MHz µs→clocks factor are compile-time
  facts duplicated in firmware and net.py; an RO clock-info register would
  make them discoverable.
- The AXI-Lite slave FSM and the 2-FF/toggle CDC idioms are copies of the
  house patterns rather than shared modules (the older copies also predate
  the ASYNC_REG attributes used here).

## Bench bring-up checklist (board + scope required)

The RTL is simulation-verified (`sim/run_stim_engine_tb.sh`,
`sim/run_stim_axi_tb.sh` — playback order, divider spacing, `t_DACWAIT` floor,
trigger modes, interlocks); these checks need hardware and have not run yet:

1. **First light**: `net.py` → `stim_sine 10 1.0 8` → 10 Hz, 1 Vpp on the DAC1
   SMA. Confirms pins, SPI timing, wake-from-power-down.
2. **Gaussian single-shot**: `stim_gaussian 1.0 5 8`; scope-check pulse shape
   and that the output returns to 0 V (power-down) afterwards.
3. **Divider accuracy**: same sine at k=8 vs k=80 → 10× period, seamless loop
   wrap (no glitch at the LOOP_INDEX seam).
4. **Trigger latency**: `stim_arm 0 edge`, pulse PMOD line 0, measure
   trigger-edge → first SYNC_N fall. Spec: < 2 frame periods + min-pulse
   filter delay.
5. **Gate + safety**: `stim_arm 0 gate` — output runs while high, stops low;
   `stim_zero` during gate-high must stop and *stay* stopped (disarm check).
6. **Upload time**: full 16 K-frame upload while idle; R2 budget ≤ 2 s
   (pipelined estimate ~0.5 s; if it misses, see the §3.9 fallback in
   `dac-stim-requirements.md`).
7. **Non-interference (V4)**: 256-channel + LFP streaming with a continuous
   stimulus looping; a clean multi-minute run shows zero SEQ gaps on both
   streams, and `netperf_loopback.py` on the host is unchanged.
8. **A/B modes**: interleaved and LDAC stereo on both SMAs; scope the ~30 µs
   interleave skew and its absence in LDAC mode.

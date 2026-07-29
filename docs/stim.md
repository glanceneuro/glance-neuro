# DAC stimulus playback

GLANCE can play arbitrary analog waveforms out of the carrier's two DAC SMA
connectors. This signal generation works independently of neural data
acquisition: you can play and trigger stimuli whether or not the amplifiers are
streaming. (Uploading a *new* waveform table is the one operation that requires
acquisition to be idle.)

You upload a table of DAC samples into a PL frame RAM; the PL then clocks that
table out to the DAC at a paced rate, on a software or hardware trigger, looping
or one-shot. In normal use you drive it through `net.py`'s `stim_*` helpers —
`stim_sine`, `stim_gaussian`, `stim_dc`, `stim_arm` — which build and upload the
waveform for you (e.g. `stim_sine 10 1.0 8` plays a 10 Hz, 1 Vpp sine); the TCP
command layer they build on is documented below.

This document explains how to use the DAC. The "Design notes" at the end record
the hardware and RTL internals for future design work — you don't need them to
use it.

## The hardware — a dual-channel DAC

The GLANCE carrier (Rev 1.1) carries a TI **DAC70502**: a **dual-channel, 14-bit**
buffered voltage-output DAC with an internal 2.5 V reference. Its two outputs
`VOUTA` / `VOUTB` drive the **DAC1 / DAC2 SMA** connectors — so "channel A" and
"channel B" throughout this document are those two physical SMAs.

- **Interface:** 3-wire SPI, **write-only** (no MISO). SCLK, SYNC_N, SDIN only.
  Because there is no readback, the firmware can verify what it *sent* (a CRC over
  the uploaded RAM) but never what the chip currently *holds*.
- **Frame:** every SPI transaction is 24 bits — `{R/W, register[6:0], data[15:0]}`
  — with the data MSB-aligned (`{DATA[13:0], 0, 0}` on the 70502). A host sample is
  a left-aligned 16-bit value, so the same table drives the pin-compatible 16-bit
  **DAC80502** unchanged.
- **Full-scale is register-selectable** (GAIN / REF-DIV): 1.25 V, 2.5 V, or 5 V.
  GLANCE uses **2.5 V** (see Power).
- **SCLK ≤ 50 MHz** is the chip's hard limit; the design runs it at a fixed
  **42 MHz** (the 84 MHz engine clock ÷ 2). Output settling is ~5 µs to ±2 LSB and
  slew is 2 V/µs, so the useful analog bandwidth is in the tens of kHz.

## Power

**The SPI pins live on Zynq I/O bank 34, whose `VCCIO34` is 3.3 V** (the Intan
interface pins share that bank and already require 3.3 V), so the pins are
constrained `LVCMOS33`. This 3.3 V rail is *why* GLANCE selects the DAC's 2.5 V
full-scale range and not the 5 V default: at a 3.3 V analog supply the 5 V range is
out of compliance — it trips the DAC's REF-ALARM and breaks the volts↔code
mapping. The firmware sets 2.5 V full-scale (REF-DIV = 1, gain = 2) as its first
real frame.

The analog outputs have a single-sided supply and **no true high-impedance state**.
The safest "off" the chip offers is per-channel **power-down**, which disconnects
the output buffer and ties the pin to AGND through 1 kΩ — parking it passively at
**0 V**. GLANCE treats power-down as the idle/off state everywhere: at boot, on
stop, and on the explicit safe-state commands. The carrier also straps RSTSEL to
GND, so the DAC powers up in SPI mode already driving **0 V** — even the window
before firmware runs is benign.

## Operating modes

Three axes combine freely: which output(s) a stimulus drives, whether it loops,
and how it is triggered.

**Channel mode** — how host samples map onto the two outputs. The PL just plays
frames; `net.py`'s frame builders lay them out:

| mode | frames / sample | per-channel rate | notes |
|---|---|---|---|
| **mono** (A, B, or broadcast) | 1 | 240 k / k | one output, or both writing the same value (BRDCAST) |
| **stereo interleaved** | 2 | 120 k / k | A then B; B lags A by one frame period |
| **stereo synchronous (LDAC)** | 3 | 80 k / k | both buffers loaded, then one LDAC frame updates them **simultaneously** |

**Playback mode** — **continuous** loops from `LOOP_INDEX` after the last frame
forever; **finite** plays a set frame count once, then returns to idle.

**Trigger mode** — **software**: a TCP command starts playback (or fires a single
finite shot) immediately. **Hardware**: a PMOD digital-in line arms the engine and
a physical edge or level starts it, with selectable polarity, a glitch filter, and
retrigger-restart. Hardware and software starts are mutually exclusive per run.

## Sampling rate and the divider

The engine has a **fixed 240 kframes/s master rate**. A runtime integer divider
**k ≥ 1** (latched at start) sets the actual frame rate:

> **frame rate = 240 kHz / k**

The per-channel *sample* rate then follows the channel mode (table above): mono is
240 k/k, interleaved 120 k/k, synchronous 80 k/k. **SCLK is unaffected by k** — the
divider paces whole frames, not the bit clock, so the SPI timing is identical at
every rate.

Worked points: **30 kS/s** (matching the amplifier rate) lands at k = 8 mono or
k = 4 interleaved; synchronous mode cannot hit 30 k exactly (nearest 20 k / 40 k).
The hard ceiling is ~600 kframes/s, set by the DAC's 1 µs `t_DACWAIT` between
updates — every k ≥ 1 is well under it.

## Buffer size

The waveform table is a **16,384-frame** PL RAM (16 × BRAM36 = 64 KB true
dual-port, one 24-bit SPI frame per 32-bit word). The `net.py` builders prepend a
couple of init frames (a CONFIG frame to exit power-down and a GAIN frame to select
2.5 V full-scale; the synchronous builder adds one SYNC-mode arm frame), so usable
sample frames are ~16,382.

Depth is not the way to get a long stimulus. At the 240 kHz master rate the whole
buffer is only ~68 ms; **long or slow stimuli come from the divider and looping**,
not from a bigger table (a full buffer looping at k = 80 already runs for seconds).

## TCP commands

The 0xA0 block, same 20-byte frame + ack discipline as every other command
(`docs/protocol.md`); `p1` / `p2` are param1 / param2.

| cmd | name | params |
|---:|---|---|
| 0xA0 | STIM_SET_WINDOW | p1 start_index, p2 end_index (inclusive) |
| 0xA1 | STIM_SET_LOOP | p1 loop_index, p2 frame_count (finite total; 0 for continuous) |
| 0xA2 | STIM_SET_RATE | p1 = k (≥ 1) |
| 0xA3 | STIM_SET_TRIGGER | p1 = line \| pol<<3 \| mode<<4 \| retrig<<6 \| arm<<7; p2 = min_pulse_µs |
| 0xA4 | STIM_START | p1 = 0 finite / 1 continuous |
| 0xA5 | STIM_STOP | — |
| 0xA6 | STIM_TRIGGER | — software single-shot (forces finite) |
| 0xA7 | STIM_ZERO | — disarm hw trigger, then configured idle state |
| 0xA8 | STIM_UPLOAD_BEGIN | p1 = start_index, p2 = total word count |
| 0xA9 | STIM_WRITE | p1/p2 = two frame words, auto-incrementing (final odd word: p2 is padding) |
| 0xAA | STIM_VERIFY | p1 = offset, p2 = count → 4-byte CRC32 reply |
| 0xAB | STIM_GET_STATUS | — → 68-byte struct (`pl_stim.h` / net.py `STIM_STATUS_FORMAT` `<8I3Q3I`) |
| 0xAC | STIM_SET_IDLE | p1 = 1 drive codes / 0 power-down; p2 = codeB<<16 \| codeA |
| 0xAD | STIM_POWERDOWN | — disarm hw trigger, outputs → 1 kΩ to AGND (0 V) |

**Uploading** (`net.py stim_upload`): `STIM_UPLOAD_BEGIN(start, count)` arms a write
pointer, then `count/2` × `STIM_WRITE` stream the words pipelined (send all, then
drain and match acks in TCP order), then `STIM_VERIFY(start, count)` CRC32s the RAM
by readback and must equal the host's `zlib.crc32` over the little-endian words.
Playing an unverified upload is a host-side protocol violation.

**Safety:** STIM_ZERO and STIM_POWERDOWN clear the hardware arm *before* driving the
safe state, so a gate still held active cannot immediately restart playback.

**Streaming interlock:** the three upload commands (BEGIN / WRITE / VERIFY) return
ACK_ERROR while acquisition streams, and BEGIN is also refused while playback runs —
you upload a new table only when idle. Playback control, triggering, and config all
work *during* acquisition, because stimulating while recording is the point.

## Design notes

You don't need any of this to use the DAC — it records the hardware and RTL
internals for whoever extends the stimulus engine next.

The stimulus spans three files that must stay in step: `stim_axi_regs.sv` (the
hardware registers), `pl_stim.{c,h}` (the firmware driver + TCP dispatch), and
`net.py` (the `CMD_STIM_*` constants and `stim_*` helpers).

**Reference design.** This is an independent implementation; the concept and the
bench-verified facts it builds on — the DAC pins (W18/R18/T17), SPI mode-1 timing,
the 16,384-frame depth, and the `completed_count` playback semantics — come from
the sibling repo `spi_dac_70502` (Cade Xinyu), the DAC70502 design for the
MicroZedIntanInterface carrier, which also served as an executable cross-check.
No code is shared between the two.

### Module structure and clocks

`stim_top` = `stim_axi_regs` (AXI-Lite, 131.25 MHz) + `stim_frame_ram`
(16384 × 32, true dual-port across the clock pair) + `stim_engine` +
`stim_spi_shifter` (both 84 MHz, reset from `proc_sys_reset_0_84M`). SCLK is fixed
at 42 MHz (84 ÷ 2), SPI mode 1, CS_SETUP = 2, CS_HOLD = 1. The engine consumes
`digital_in_0[7:0]` (trigger source) and the acquisition `master_timestamp`
(start/stop latching) — both already in the 84 MHz domain, so no CDC there. Frame
pacing is one frame per 350·k clocks; k = 1 (4.17 µs) already clears the DAC's
~1.6 µs floor, so every k ≥ 1 is legal by construction.

### AXI-Lite register map — base `0x43C00000`, 128 K

`0x00000..0x00048` registers; `0x10000 + 4·i` = frame RAM word *i* (RW; reads back
for CRC verification).

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

### Engine semantics (details in `stim_engine.sv`)

- **Config is latched at start:** mid-run writes to MODE / RATE_K / indices take
  effect at the next start, not immediately. Trigger-conditioning fields
  (line / pol / minpulse) act live.
- **Every stop path drains to a safe idle.** Stop, gate-low, count-complete, zero,
  or power-down each drain the in-flight frame, then emit the idle sequence —
  power-down (CONFIG 0x030003) or driven idle codes per MODE[9] — with a full master
  period at the seam so `t_DACWAIT` holds. `running` clears at the drain; `TS_STOP`
  latches only when the idle sequence finishes.
- From idle, force_zero / force_powerdown / dac_soft_reset emit maintenance frames
  without touching run bookkeeping.
- RAM writes while running are blocked and set sticky STATUS[4]; a start with invalid
  config (k = 0, start > end, loop > end, finite count 0) is refused with sticky
  STATUS[5].
- **Reading multi-word status:** COMPLETED / TS_* / CURRENT cross domains as plain
  2-FF words, so read them once the state they describe is settled. The settled
  condition is **running == 0 AND idle_seq_active == 0** (STATUS bits 0 and 6), not
  `running` alone. While running, accept debug-grade skew.
- **Write one one-shot CONTROL bit per AXI write.** The W1P bits cross the clock
  domain as independent toggles, so two written together can arrive a cycle apart and
  race each other's side effects (the driver already obeys this).
- The engine accepts start/maintenance pulses only from its idle state; a pulse in
  the drain/idle-sequence window is discarded. The driver waits for full idle before
  start and issues safe-state commands with a settle-and-confirm retry, so an acked
  command has taken effect.

### Boot state

`pl_stim_boot_init()` (from core-0 init): engine soft-reset → DAC soft-reset frame
(TRIGGER = 0x0A) → 300 µs (DAC POR takes 250 µs) → CONFIG power-down. Outputs sit at
1 kΩ-to-AGND (0 V) until the first playback; with RSTSEL = GND even the pre-firmware
window drives 0 V.

### Known limitations / deferred hardening

Reviewed and consciously deferred (none block v1; each is an engine-RTL change that
warrants its own tested commit):

- A hardware retrigger edge landing in the engine's 2-cycle RAM-read pipeline is
  dropped (~0.6% of async edges at k = 1); and the retrigger reload samples the live
  FRAME_COUNT rather than the start-latched copy, so rewriting config mid-run while
  retriggering can tear. Rule until fixed: treat all config as frozen while running
  (which is the intended usage anyway).
- Register decode ignores address bits [15:7], so undefined offsets in the low 64 K
  alias onto the register file without SLVERR — drivers must stay inside the map.
- The master rate (240 kf/s) and the 84 MHz µs→clocks factor are compile-time facts
  duplicated in firmware and net.py; an RO clock-info register would make them
  discoverable.
- The AXI-Lite slave FSM and the 2-FF/toggle CDC idioms are copies of the house
  patterns rather than shared modules.

### Bench bring-up checklist (board + scope required)

The RTL is verified in simulation (playback order, divider spacing, `t_DACWAIT`
floor, trigger modes, interlocks); these checks need a board and a scope and have
not run yet:

1. **First light:** `stim_sine 10 1.0 8` → 10 Hz, 1 Vpp on the DAC1 SMA. Confirms
   pins, SPI timing, wake-from-power-down.
2. **Gaussian single-shot:** `stim_gaussian 1.0 5 8`; scope the pulse shape and that
   the output returns to 0 V (power-down) afterwards.
3. **Divider accuracy:** the same sine at k = 8 vs k = 80 → 10× period, seamless loop
   wrap (no glitch at the LOOP_INDEX seam).
4. **Trigger latency:** `stim_arm 0 edge`, pulse PMOD line 0, measure trigger-edge →
   first SYNC_N fall. Spec: < 2 frame periods + min-pulse filter delay.
5. **Gate + safety:** `stim_arm 0 gate` — output runs while high, stops low;
   `stim_zero` during gate-high must stop and *stay* stopped (disarm check).
6. **Upload time:** full 16 K-frame upload while idle; budget ≤ 2 s (pipelined
   estimate ~0.5 s).
7. **Non-interference:** 256-channel + LFP streaming with a continuous stimulus
   looping; a clean multi-minute run shows zero SEQ gaps on both streams, and
   `netperf_loopback.py` on the host is unchanged.
8. **A/B modes:** interleaved and synchronous stereo on both SMAs; scope the
   one-frame-period interleave skew and its absence in synchronous mode.

# Unified single-port packet format (no-loss, no-MTU-framer)

Status: **the wire format**, and the single source of truth for it — the PL, the firmware,
`net.py` and the Open Ephys plugin all implement exactly this. Change it and all four move
together, along with `docs/protocol.md` and `docs/register-map.md`.

## Principles (from the CLAUDE.md hard rule)

1. **One UDP port** (default **0x6800 / 26624**) for ALL PL→host streams. The host demuxes by
   `stream_type` in the header. (Board-side this is TX-neutral; host-side we drain
   promiscuously so broadband is never blocked.)
2. **NO DATA LOSS.** Every packet fits **one standard datagram** (≤ 1472 B payload → no IP
   fragmentation, no jumbo, **no MTU framer**). We *specify* the data so it inherently fits;
   if a config wouldn't fit, we **reduce the spec**, never chunk-with-loss.
3. **Loss is provably zero**, not assumed: every packet carries a **per-stream monotonic
   sequence number**; the host flags any gap. Broadband's gap count must stay 0.

## Why one port (not one per stream)

The board could just as easily send each stream to its **own** UDP port — the PL builds
the complete wire packet (header + payload) in its output BRAM and the PS DMAs it straight
into a `PBUF_REF`, so a per-stream destination port costs the board nothing. The single
port is driven entirely by a **receiver-side** failure mode:

If a per-stream port has **no socket draining it** (that stream's consumer isn't running —
e.g. a viewer is closed), the receiving host's **OS kernel** — *because nothing is
listening* — replies **ICMP "port unreachable"** to every datagram sent there. At stream
rate that is a multi-kHz inbound flood, and the board's **fully-polled** lwIP stack
(`NO_SYS`, no interrupts) must receive and process every one of those ICMP replies. That
steals time from the 30 kHz acquisition loop (recv→transmit spikes to 40–60 µs against a
~33 µs budget) and drives catch-up bursts that exhaust the TX descriptors → **dropped
broadband**. Measured on the separate-LFP-port design: broadband-only pristine (~27 µs max,
0 over-budget, 0 drops); the LFP port left **undrained** → ~63 µs, ~250 over-budget, ~12
drops; that same port **drained** → identical to broadband-only. The firmware was never the
bottleneck — an unlistened UDP port was.

One port removes the failure mode **structurally**: there is only ever one socket, broadband
keeps it drained continuously, and an unconsumed stream (e.g. LFP) is simply demuxed and
ignored — it never lands on a dead port, so the host never emits ICMP and the board never
sees the storm. A host-side "always drain every stream port" rule also works, but it is
fragile (a GUI viewer can be closed mid-run); the single port makes it impossible to get
wrong. This is why principle 1 is one port + a `stream_type` tag, not a port per stream.

## Common header — 8 × 32-bit little-endian words (32 bytes), identical for every stream

| word | name | contents |
|------|------|----------|
| 0 | `MAGIC` | `0xCAFEBABE` (all PL packets) |
| 1 | `TYPE_VER` | `[7:0]` stream_type · `[15:8]` version (=1) · `[31:16]` flags |
| 2 | `TS_LO` | 64-bit master timestamp, low word |
| 3 | `TS_HI` | 64-bit master timestamp, high word |
| 4 | `SEQ` | per-stream packet sequence, +1 each packet of that stream (wraps 32-bit) |
| 5 | `AUX0` | stream-specific (below) |
| 6 | `AUX1` | stream-specific (below) |
| 7 | `RSVD` | 0 (reserved; candidate for a future CRC32 of the packet) |

`stream_type`: **1 = BROADBAND, 2 = LFP, 3 = IMU.** Numbers are handed out in the order
streams actually ship, with no reserved gaps — a held-open middle number only invites a
mismatch between what a reader assumes and what is on the wire. The next stream to land
takes 4, whenever there is one.

The host demuxes on `TYPE_VER[7:0]`. **Per-stream `SEQ` continuity = the loss check.** Keep
each stream's `SEQ` independent so broadband's integrity is unaffected by the others.

## Per-stream payloads

### BROADBAND (type 1) — unchanged content, re-framed
- `AUX0` = `channel_enable[7:0]` · `num_data_words[23:8]`
- `AUX1` = digital-in / metadata (preserve today's fields)
- Payload = the existing per-packet fields that don't fit the header (the 8 external-ADC
  values, any remaining metadata) **followed by** the data words. **Map ALL of today's
  10-word-header content into the new header + a small broadband sub-block — lose nothing.**
- Already ≤ 1 datagram (≤140 data words + header ≈ 600 B). Fits trivially.

**As implemented:** the broadband frame is the 8-word common
header **+ a 6-word broadband sub-block = 14 header words** ahead of the data (the PL
writes these as 7 × 64-bit FIFO header writes). Word map (32-bit LE):

| word | contents |
|------|----------|
| 0 | `MAGIC` = 0xCAFEBABE |
| 1 | `TYPE_VER` = 1 \| version<<8 \| flags<<16 |
| 2 / 3 | 64-bit master timestamp |
| 4 | `SEQ` (broadband per-stream, +1/packet; resets to 0 on START) |
| 5 | `AUX0` = `channel_enable[7:0]` \| `num_data_words[23:8]` |
| 6 | `AUX1` = `digital_in[7:0]` \| `aux_flags[15:8]` \| `echo_sweep[31:16]` (this packet's slot-0/accel command; its reply is data word 34) |
| 7 | `RSVD` = 0 |
| 8 | sub-block: prev-packet slot-1 (fs) \| slot-2 (inject) aux echoes = `{echo_inject[31:16], echo_fs[15:0]}` (replies land at data words 0/1) |
| 9..12 | sub-block: the 8 external-ADC breadcrumbs (currently 0) |
| 13 | sub-block: reserved (0) |
| 14.. | DATA words — **byte-identical** to the legacy format |

Verified in `programmable_logic/sim/dualport_dropout_tb.sv`: the data words still match
the legacy sine reference EXACTLY (content preserved) and SEQ/timestamp advance by 1 per
packet (the loss check). Max packet = 14 + 140 = 154 words = 616 B (≤ 1 datagram).

### LFP (type 2)
- `AUX0` = `lane_mask[7:0]` · `decim_R[15:8]` · `num_taps[23:16]` · `overrun[24]`
- `AUX1` = `num_samples`
- Payload = the decimated samples (int16, as today). One frame ≤ 1 datagram. Fits.

**As implemented:** the LFP frame is exactly the 8-word common
header (no sub-block) then the decimated samples. `num_samples` = `popcount(lane_mask)·32`
(`lane_mask` mirrors the broadband `channel_enable`). The PL builds the whole frame
(header + samples) in its output BRAM; the PS DMAs it and sends it on UDP 0x6800 with
stream_type=2. The cascade was validated in simulation against the reference response from
`design_lfp_filters.py`; that bench was retired once the engine was built and tested on
hardware, per `docs/TESTING.md` — one-off benches are deleted outright rather than carried,
and git history keeps them.

### IMU (type 3) — BNO055 side channel

One datagram per fused sample (default 100 Hz per port, `CMD_IMU_STREAM`), 8-word
common header + 5 payload words = **52 bytes**. The one PS-built stream: its source
is I2C (not a PL BRAM), so the firmware assembles the packet and stamps it with
`pl_get_timestamp()` when the sample completes — IMU samples land on the **same
master clock as the neural data**, which is the point of ingesting them on-board.

- `TYPE_VER` flags: bit 16 = port (0 = A, 1 = B). Each port is its own stream with
  its own `SEQ` (starts at 0 on `imu_stream` start). A failed send is never retried
  (the next sample is 10 ms away and fresher), so a SEQ gap = exactly one lost sample.
- `AUX0` = `period_ms[15:0]` · `iic_errors[23:16]` · `send_drops[31:24]` (both
  counters saturate at 255 — health at a glance).
- `AUX1` = `calib_stat[7:0]` (BNO055 CALIB_STAT: `[7:6]`sys `[5:4]`gyr `[3:2]`acc
  `[1:0]`mag, 3 = calibrated; `0xFF` until the first housekeeping read) ·
  `opr_mode[15:8]` · `temp_c[23:16]` (die temperature, int8).
- Payload = 10 LE int16: quat `w,x,y,z` (1 = 2^14), acc `x,y,z` (1 LSB = 0.01 m/s²),
  gyr `x,y,z` (1 LSB = 1/16 °/s).

Source: `firmware/src-core0/pl_imu_stream.c` (non-blocking AXI IIC state machine in
the main loop). Verified host-side in `firmware/test-host/` (simulated IIC core +
BNO055) and cross-checked against `net.py parse_imu_packet` by
`remote/test_imu_host.py`, which parses datagrams the (simulated) firmware emitted.


## Host (net.py + Open Ephys)

- **One socket, port 0x6800, promiscuous drain:** a tight `recvfrom → ring` loop that never
  blocks on processing; demux + per-stream handling happen downstream. Big `SO_RCVBUF`.
- Demux by `TYPE_VER[7:0]`; verify per-stream `SEQ` continuity (the loss check).


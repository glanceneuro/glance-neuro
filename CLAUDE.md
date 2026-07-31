# CLAUDE.md

Working notes for this repo. Read `docs/` for the reference material; this file is
the part that is easy to get wrong.

## What this is

A neural acquisition system on a MicroZed (Zynq-7020): programmable logic samples up
to 256 amplifier channels from Intan RHD chips at 30 kHz, bare-metal firmware on
core 0 streams them over UDP, and a host client (`remote/net.py`) or the Open Ephys
plugin consumes them. A second stream carries an on-PL decimated LFP band at 3 kHz.

**One datagram per 30 kHz sample.** That is the point of the product, not an
implementation detail — see the hard rules.

## Repo layout

| path | what |
|---|---|
| `programmable_logic/src/` | RTL. Every `*.v`/`*.sv` here is a build input |
| `programmable_logic/block_design/` | `design_1_bd.tcl` — AXI wiring, BRAMs. A build input |
| `programmable_logic/ip/` | custom Intan SPI IP. A build input |
| `programmable_logic/sim/` | testbenches, runners, filter design script, coefficients |
| `firmware/src-core0/` | network, streaming, PL control |
| `firmware/include/main.h` | the PS side of the register/packet contract |
| `remote/net.py` | reference host client and diagnostic tool |
| `blobs/` | the SD card image (copied verbatim to the FAT root): `BOOT.bin` + any runtime fabrics, matching the source in the same commit — see rule 1 |
| `docs/` | protocol, register map, LFP cascade, testing |

## Hard rules

These are not preferences. Violating one is a reason to stop and ask.

**1. Never ship source and binary out of step.** `blobs/` **is the SD card image** —
its contents are copied verbatim to the FAT root. It always holds `BOOT.bin` (the boot
image; the BootROM requires exactly that name) and, in the deferred-boot model, the
fabric `*.bin` files loaded at runtime. One config's image lives in `blobs/` per branch;
`BOOT.bin` is built from different source depending on that config:

| config (branch) | `blobs/` contents = the SD card | built by |
|---|---|---|
| acquisition | `BOOT.bin` ← `firmware/src-core0`, `firmware/include`, `programmable_logic/{src,ip,block_design/design_1_bd.tcl}` | `scripts/build.sh` |
| deferred acq (**current — this branch's product**) | `BOOT.bin` ← `firmware/src-core0` + `firmware/src-core1` + `firmware/include` + `programmable_logic/{src,constraints,block_design,ip}` (the baked acq bitstream); `acq.bin`/`aimu*.bin` ← the respective PL | `scripts/build_acq_loader.sh` |
**`BOOT.bin` is a PL artefact as well as a firmware one** — it carries a bitstream, so a
`programmable_logic/` change must rebuild it, not just the fabric `.bin`. The build script
enforces this with a source fingerprint (ported from `build.sh`): `--app-only` **refuses**
rather than baking a stale fabric. Note the inputs the older rows omitted and this one
does not: `constraints/` (the acq project globs `*.xdc`, and `uart.xdc` is what pins the
console), `src-core1` (its ELF is inside `BOOT.bin`), and the fact that the Vitis platform —
hence the FSBL and BSP — is generated from the **acq_imu_both** `.xsa`, so an
`acq_imu_both_*` edit changes `BOOT.bin` too.

The bitstream is baked because the debug UART leaves the chip through PL balls: a blank PL
means no serial console and an unlit DONE LED. See `docs/deferred-boot.md`.

**Do not run `scripts/build.sh`, `scripts/build_detect.sh` or `scripts/build_loader.sh` on
this branch.** Each writes `blobs/BOOT.bin` from a *different* bif — `build_detect.sh`
overwrites it in place, and `build_loader.sh` reinstates the blank-PL boot that costs the
console and the DONE LED. They belong to the older configs above, kept for reference.

A commit that changes a source subtree rebuilds every artefact that lists it. The
corollary bit me once: the `src-detect` app grew the loader but the baked `BOOT.bin`
image wasn't rebuilt, so it went stale. So: after touching a subtree, rebuild its
artefact(s), and **don't leave a superseded or foreign config's blob in `blobs/`** on a
branch where it isn't the product (the deferred-boot branch's `BOOT.bin` is the loader,
not the monolithic acquisition image). These are the only supported build scripts; each
decides what to rebuild and verifies what it produced. Don't hand-run the underlying
Vivado/Vitis steps — that is how stale artefacts ship. If a build fails, bring it to the
user rather than working around it, and refuse to commit. (A `blobs` manifest +
`check_blobs.sh` to enforce this across artefacts is planned — see `docs/deferred-boot.md`.)

**2. Single-sample latency is the reason this exists.** One 30 kHz sample per
datagram. Never propose batching samples, coalescing datagrams, jumbo frames, or an
MTU framer to improve throughput. If the host cannot keep up, that is a regression to
find, not a ceiling to accept — start with `netperf_loopback.py`.

**3. No data loss.** Per-stream sequence numbers make loss provably zero, and a clean
run shows zero gaps. If a feature cannot fit the budget, reduce the feature — fewer
channels, fewer octaves — rather than accept dropped packets.

**4. Don't copy packets, and don't allocate on hot paths.** The receive path is
zero-copy by design (`recv_into` into a reused buffer, `memoryview`, parse in place).
Anything per-packet — a copy, a slice, a lock, a list — is paid 30,000 times a second.

**5. Comments explain the code as it is.** No references to what was removed, which
commit changed it, or how it used to work. A reader has no access to that history and
should not need it. Explain *why* the current shape is the way it is when the reason
is not obvious — especially where it is load-bearing.

## The contract

`firmware/include/main.h`, `remote/net.py`, and the Open Ephys plugin are **three
consumers of one contract**. Change it and all three move together, along with
`docs/protocol.md` and `docs/register-map.md`. A `_Static_assert` on the status struct
keeps the firmware and `net.py` honest; nothing enforces the plugin, so check it by hand.

Bit positions in the packet header are part of the wire format. A field written to the
wrong bits is not a decode error — it reads as a plausible value. An overrun flag that
lands outside its bit reports "no overrun" forever.

## Diagnosing

Measure before theorising. This is the lesson that cost the most.

- A plausible mechanism is not evidence. Get a number that distinguishes your
  hypothesis from its alternatives, and be willing to have it disproved.
- **Run the host gate first** on any packet-loss report:
  `python3 remote/netperf_loopback.py 30 20 154 0`. It is pure loopback, needs no
  board, and takes 20 seconds. A degraded host has repeatedly looked exactly like a
  firmware bug.
- When a symptom appears and disappears, find what state persists. Faults that clear
  on reboot come back mid-experiment.
- If a fix does not measurably do what you claimed, say so plainly rather than letting
  it stand as the explanation.

## Gotchas

- The PL crosses two clock domains (131.25 MHz AXI ↔ 84 MHz data path) through
  synchronisers in `axi_lite_registers.v` and the dual-port BRAM. The clocks are
  declared asynchronous — don't add single-cycle paths between them.
- The 84 MHz data path must be reset from `proc_sys_reset_0_84M`, not the AXI-domain
  reset: a cross-domain reset fails timing on ~20k endpoints.
- `write_fifo` in `fifo_bram_interface.sv` is deliberately not reset element-by-element
  — resetting it forces ~18k flip-flops and a routing hotspot. Unreset, it infers
  LUTRAM, which is safe because entries are only read after being written.
- Many control registers latch **only while transmission is inactive**. Changing phase,
  channel mask, or COPI words mid-stream has no effect until stop/start.
- Every `Xil_In32` is an AXI-Lite transaction that stalls the core until the PL
  answers. In a loop that also services lwIP and the 33 µs sample budget, poll only
  what you need, only when you need it.
- `net.py` runs on macOS and Linux; guard platform-specific socket options with
  `hasattr(socket, ...)` (see `configure_tcp_keepalive`).

## Conventions

- `vivado_project/` and `vitis_workspace/` are generated and gitignored. Never commit
  them.
- Source files carry SPDX headers. This repo is MIT; the plugin repo is GPL-3 and the
  hardware repo is CERN-OHL-P. When moving code between them, keep the destination's
  header — copying a file verbatim from another tree silently strips it.
- Plain forward commits. Don't rebase shared branches. No AI attribution trailers.
- **Always push your work; never leave it local, never push straight to `main`.** The
  build host sits in the lab but has no link to the board (separate subnet, no JTAG, no
  SD card), so the user can only test what has been pushed — unpushed work is
  untestable. Stage everything on a `testing/<topic>` branch to keep `main` and other
  shared branches clean; the user pulls that branch to flash and test.
- See `docs/TESTING.md` for what earns a test and what gets retired.

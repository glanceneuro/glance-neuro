# Deferred-load / multi-bitstream boot (step 2)

> **How to read this file.** It is the DESIGN NOTE the feature was planned from, and parts
> of it describe a model that was tried and then superseded. What SHIPS today is: the FSBL
> configures the PL from a bitstream baked into `BOOT.bin`, and fabrics are swapped at
> runtime on host command. The blank-PL boot this note originally proposed was implemented,
> shipped, and reverted — it cost the serial console and the DONE LED, because the debug
> UART leaves the chip through PL balls.
>
> **Authoritative here:** "New boot flow", "Bitstream inventory", "Hardware-validated boot
> rules". **Historical, kept for the reasoning:** "Why it works", "Orchestration",
> "Increments", "Build & commit discipline" (superseded by CLAUDE.md rule 1's current
> table). Sections in the second group are marked where they contradict the shipped code.

Design note for the "network-first, then load a fabric" boot model. Step 1 (the
IMU detector, `docs/imu-detect.md`) proved I2C detection on a single baked-in
bitstream. Step 2 changes *how the PL gets loaded* so one SD image can bring up
whichever fabric the plugged-in headstages need — decided at runtime, after the
network is already up.

## Why it works *(historical — the PL-independence argument)*

> The reasoning below is sound and still explains why runtime swaps are possible at all.
> But the conclusion it was used for — boot with the PL blank — did not survive contact
> with the board: the console UART is **not** a PS-only resource on this carrier. It is
> EMIO to PL balls, so "DDR, clocks, UART | PS hard blocks | no" is wrong for *this*
> hardware, and that error is what made a blank boot look acceptable on paper.

Every peripheral bring-up needs is a **PS/MIO** block, none of them PL:

| function | where | needs PL? |
|---|---|---|
| Ethernet (GEM0) | MIO 16–27, MDIO 52–53 | no |
| SD card | MIO (SDIO) | no |
| DDR, clocks, UART | PS hard blocks | no |
| headstage I2C / SPI | **PL bank-35 pins** | **yes** |

So the PS, DDR, lwIP, and the SD card are all fully up with **no PL configured at
all**, and they *survive* a PL reconfiguration. The PL is optional and loadable
at any time from the running app. That independence is the whole basis for the
model.

With no bitstream loaded, the PL I/O sit unconfigured / Hi-Z — safe against any
headstage (nothing is driven), just unusable until a fabric is loaded.

## New boot flow

```
BootROM → FSBL: PS up (DDR, clocks, MIO Ethernet/SD/QSPI), CONFIGURE THE PL from the
                bitstream baked into BOOT.bin, load both core ELFs
   app: acq_pl_init_early() (CDMA + TLB) -- BEFORE the network, for link stability
   app: lwIP up over MIO GEM → link → core 1 wakes → command server + beacon
   app: acq_pl_init_late() (the print-heavy register setup), pl_is_acq = 1
   app: host connects; set_config / rescan PCAP-swaps a fabric over the SETTLED link
        → level shifters + FPGA resets → re-init drivers → probe / acquire
```

**No PCAP runs at boot.** That is the point: the FSBL configures the PL, which is `main`'s
long-proven path, and the runtime-PCAP hazard below applies only to swaps made from the
live app. The console exists from the FSBL's first line because the debug UART leaves the
chip through PL balls — a blank PL is silent (see the console note under the boot rules).

The app is the **persistent orchestrator**: it lives in DDR/OCM and keeps
running — network up — across PL reconfigurations, so the host stays connected
while the board swaps fabrics under it.

## Zynq-7000 implementation path (verified against Vitis 2025.1)

- **PCAP programming: `XDcfg` (`devcfg_v3_8`), NOT XilFPGA.** XilFPGA in this
  toolchain is ZynqMP-only (all its interface code is under `.../zynqmp/`). The
  Zynq-7000 path is the classic device-config driver: `XDcfg_LookupConfig` →
  `XDcfg_CfgInitialize` → `XDcfg_Transfer` (DMA the bitstream to PCAP). The
  `ps7_dev_cfg_0` block is a fixed PS7 peripheral, present regardless of BD
  config, so the driver always instantiates.
- **SD access: `xilffs` (FatFs).** Added to the app's BSP like `lwip220`;
  `f_mount` / `f_open` / `f_read` the bitstream file into a DDR buffer.
- **Bitstream file format: PCAP `.bin`, not `.bit`.** `XDcfg_Transfer` wants a
  raw, byte-ordered bitstream with no `.bit` header. bootgen produces it:
  `bootgen -image <bif> -arch zynq -process_bitstream bin` → `<name>.bit.bin`.
  Ship that `.bin` on the SD FAT partition; never the raw `.bit`.
- **After every load — the FSBL-replacement sequence (easy to forget):** FSBL
  normally does this when it programs the PL, so the app must do it now:
  1. `XDcfg_Transfer` the bitstream, poll `XDcfg_IsDmaCommandDone` / PCAP done.
  2. **Enable PS↔PL level shifters** and **release the FPGA resets** via SLCR
     (`FPGA_RST_CTRL` 0xF8000240 → 0, `LVL_SHFTR_EN` 0xF8000900 → 0xF), with the
     SLCR unlock (0xF8000008 = 0xDF0D) around it.
  3. Re-assert/-release the design's `proc_sys_reset` and re-init every
     PL-facing driver (AXI regs, IIC, and — in acquisition — DMA).
- **Before reconfiguring a *running* fabric:** quiesce any PL AXI master (the
  acquisition CDMA) and stop streaming first, so nothing is mid-transaction when
  the fabric disappears. (Not an issue for the blank→detect first load.)

## Bitstream inventory (files on the SD FAT partition)

`blobs/` **is** the SD card image — its contents are copied verbatim to the FAT root.
`BOOT.bin` carries **FSBL + the default acquisition bitstream + both core ELFs**, and the
swappable fabrics live beside it as plain files. (An earlier revision of this design made
`BOOT.bin` bitstream-free; that is what cost the serial console and the DONE LED, and it
was reverted — see the resolved item under the boot rules.) The shipped set is:

| file | fabric | when |
|---|---|---|
| `acq.bin` | both ports 128-ch LVDS, no I2C | no IMU on either cable; also the fabric baked into `BOOT.bin` |
| `aimuboth.bin` | both ports 64-ch + a BNO055 each | IMUs on both cables — and the fabric the IMU census runs on, being the only one with I2C on both ports |
| `aimu_a.bin` / `aimu_b.bin` | one port 64-ch + IMU, the other 128-ch LVDS | mixed |

That collapse did happen, though not as sketched: `aimuboth` — an *acquisition* fabric —
is both the census fabric and the streaming fabric whenever both cables carry an IMU, so
that case needs no second load at all. The separate detect/scan fabric it was originally
built around is retired.

## Build & commit discipline *(historical — see CLAUDE.md rule 1 for what shipped)*

> The manifest below was never implemented. What replaced it: rule 1's table names every
> artifact and its inputs, and `build_acq_loader.sh` carries a source fingerprint that
> refuses `--app-only` when the PL has changed.


Today `build.sh` emits one `blobs/BOOT.bin` and CLAUDE.md rule 1 is "any commit
touching `programmable_logic/`/`firmware/` carries a `BOOT.bin` built from that
exact source." The multi-image model breaks the one-to-one: a commit now
produces **FSBL + app + several bitstream `.bin`s**, and *all* of them must be
provable against the same source.

Proposed discipline (to replace, not weaken, rule 1):

- `build.sh` emits a **`blobs/` set**: `BOOT.bin` (FSBL+app) plus each
  `*.bin` fabric, and writes a **`blobs/MANIFEST.sha256`** listing every blob
  with its hash and the source commit. One script call builds and hashes the
  whole set; nothing is hand-built.
- The "can't ship stale" rule becomes "the manifest matches the tree" — a commit
  touching PL/firmware carries a regenerated `MANIFEST.sha256` covering every
  blob. A `scripts/check_blobs.sh` verifies tree ↔ manifest so a stale fabric is
  caught the same way a stale `BOOT.bin` is today.
- SD provisioning copies `BOOT.bin` + every `*.bin` named in the manifest.

This is the main real cost of step 2 and the reason for a design note before
code: it touches the sacred invariant, so the manifest approach needs your read
before it's baked into `build.sh`.

## Orchestration *(historical — built, but host-side)*

> Shipped differently: the state machine lives in the HOST (`net.py rescan`, and the
> plugin's `rescanDevice`), not in the app. It censuses on `aimuboth`, picks the matching
> `acq_imu_*` variant, loads it, then runs the phase sweep. Keeping it host-side means the
> board never auto-loads anything, which is what keeps every PCAP swap clear of the
> GEM/PHY bring-up window.

The original sketch: on boot (PL blank) → `load detect.bin` → probe both ports (I2C
CHIP_ID + high-Z level sense) → classify each port (128-ch / 64-ch+IMU / empty) → pick the
matching `acq_XX.bin` → load it → start acquisition.

## Increments *(historical — the plan as executed)*

> 2a and 2c landed; the blank-PL half of 2a was later reverted (see the banner). 2b's
> manifest was never built — CLAUDE.md rule 1 plus the build script's PL fingerprint cover
> the same ground.

- **2a — deferred-load proof** *(done, then partly superseded)*: orchestrator app
  boots with a blank PL, network comes up, `load_pl detect` loads `detect.bin`
  from SD via PCAP + the level-shifter/reset sequence, and `detect_imu` then reads
  chip_id 0xA0 *through the just-loaded fabric*. Proves network-first +
  PCAP-from-SD + post-load driver use end to end, reusing the validated detect
  bitstream as the payload. `BOOT.bin` (FSBL+app, no bitstream) + `detect.bin` in
  `blobs/`; `net.py load_pl`; `pl_ready` guard so `detect_imu` refuses on a blank
  PL instead of hanging on unconfigured PL AXI.
- **2b — multi-image + manifest**: `build.sh` emits FSBL+app + all fabrics +
  `MANIFEST.sha256`; `check_blobs.sh`; SD provisioning; the auto
  detect→select→load state machine.
- **2c — acquisition integration**: fold the orchestrator into the real
  acquisition firmware/build and validate a live streaming fabric loaded over
  PCAP (CDMA quiesce/re-init across reconfig). The big one.

## Caveats / risks

- **Reconfig downtime**: a full 7z020 bitstream over PCAP is ~10s of ms.
  Trivial for a between-sessions config step; acquisition is down during it.
- **Driver re-init after each load** is mandatory (see the sequence above);
  skipping the level-shifter/reset step is the classic "loaded but the PL looks
  dead" failure.
- **Blob provisioning discipline** (above) is the real cost — get the manifest
  right or the "can't ship stale" guarantee quietly erodes across N files.
- **No boot-time serial console on this board — the risk that came true, now fixed
  by baking.** The console UART (UART1) is routed through the PL — EMIO to the
  FT230 on M14/M15 (`constraints/uart.xdc`), not MIO — so it only exists once a
  fabric that routes it is loaded. A blank-PL phase is therefore silent on serial
  *by construction*, and this note called it before the board did: shipping the
  blank boot produced exactly this symptom, plus an unlit DONE LED, and it read
  as a dead board. The fix is to bake the default acq bitstream back into
  `BOOT.bin` so the FSBL configures the PL first (see the resolved item under
  "Hardware-validated boot rules"). The lesson worth keeping: **on this carrier
  the console is a PL-dependent resource, so any future boot mode that leaves the
  PL blank silently gives up both serial diagnostics and the DONE LED.**

## Hardware-validated boot rules (on the board)

The deferred acquisition firmware (src-core0 orchestrator, network-first blank boot,
`set_config` PCAP-swap) is validated on hardware: blank boot → `net.py` connects →
`set_config acq_imu_both` loads the freed-pin dual-IIC fabric over the live link →
`detect_imu` reads a BNO055 (chip_id `0xA0`) on the cabled port. Two rules were paid for
in that bring-up:

- **Network-FIRST is mandatory; do NOT PCAP-load a fabric near the GEM/PHY bring-up
  window.** Loading a fabric *before* `lwip_init` left the MAC unable to transmit at all
  (zero frames, board unreachable); loading *right after* link-up dropped the PHY
  (err −4). A load over a fully-settled link (a host `set_config`, seconds later) is safe
  — the link survives. So boot with the PL **blank**, bring the whole network + command
  server up, and load fabrics only on command; `main.c` holds `pl_is_acq = 0` until the
  first load so no PL-touching service runs on a blank PL. (Exact mechanism of the
  near-window fragility is not yet pinned — likely the reconfig transient, or the
  `Xil_SetTlbAttributes`-vs-EMACPS-BD-ring ordering; characterize it before any
  *auto*-load or the rescan orchestrator, both of which depend on runtime swaps.)
- **Fabric blob filenames must be 8.3 (≤8-char base).** The loader's xilffs is built
  `FF_USE_LFN=0`, so `f_open("0:/<name>.bin")` fails `PL_ERR_OPEN` on a longer base name
  even when the file is present. `acq.bin` / `detect.bin` fit; `acq_imu_both.bin` did not
  and ships as **`aimuboth.bin`**. The host-facing config *name* (net.py `CONFIGS`) is
  unconstrained; only the SD `file` in `pl_configs` must be 8.3. Future
  `acq_imu_port_a/_b` blobs need 8.3 names too.

- **RESOLVED — the default fabric is baked into `BOOT.bin` again.** `boot_acq_loader.bif`
  stages the acq bitstream between the FSBL and the app ELFs, so the FSBL configures the PL
  before the GEM or lwIP exist — the path `main` has always shipped and which networks
  reliably on this board. Console and DONE LED are therefore live from power-on, and a boot
  where the network fails is still visible on serial. Firmware adopts reality rather than
  assuming: `pl_loader_pl_configured()` (a PS register read, so it cannot hang) decides
  between "PL live at boot" and the blank path, which still works if the bitstream is ever
  omitted. Runtime `set_config` swaps are unchanged and still happen over a settled link.

  This does **not** contradict the network-first rule below. That rule is about *runtime
  PCAP reconfiguration* — PROG_B clearing the whole PL plus level-shifter and
  `FPGA_RST_CTRL` toggles, issued from a live app — landing next to GEM/PHY bring-up. An
  FSBL-configured PL performs no PCAP at boot at all, which is why baking was always safe
  and blank-booting was the thing that cost the console. The two were conflated once;
  don't conflate them again.

  Consequence for build discipline: `BOOT.bin` is now a **PL artifact as well as a firmware
  one**, so a `programmable_logic/` change must rebuild it (CLAUDE.md rule 1).
  `--app-only` reuses the existing bitstream and is valid only for firmware edits.

- **Why blank boot cost the console** (kept, because it explains the symptom and the
  constraint that made baking the right answer). The debug UART is
  **UART1 on EMIO**, not MIO: `design_1_bd.tcl` sets `PCW_UART1_UART1_IO {EMIO}` and brings
  `UART1_TX_0` / `UART1_RX_0` out as top-level PL ports, which `constraints/uart.xdc` pins
  to **M14/M15** (JX2 → the FT230 USB-serial bridge). With no fabric configured those pins
  have no routing at all, so every character — FSBL included — goes nowhere.

  | PL state | console | why |
  |---|---|---|
  | blank (from power-on) | **no** | EMIO UART signals have no PL routing |
  | `scan` / `detect` | **no** | that BD creates *no* top-level ports, so its EMIO UART is never brought out (which is also why it passes DRC with only `detect_pins.xdc`) |
  | `acquisition`, `acq_imu_*` | yes | full constraint set includes `uart.xdc` |

  With the bitstream baked the console is live from power-on, but the dark window still
  exists *mid-session*: a `rescan` passes through the `scan` fabric, whose BD brings out no
  top-level ports, so serial goes quiet for that second and returns when the acquisition
  variant loads. Writing to the UART while dark is **safe** — UART1 is a PS peripheral at
  `0xE0001000`, always present, so the writes complete and only the bits on the wire are
  lost. Nothing hangs.

  This is what made a blank boot untenable: with no fabric AND no network there was no
  diagnostic channel at all, and a boot failure was invisible on both. Baking restores the
  property the older image had. A carrier respin could route the FT230 to MIO instead and
  make the console genuinely PL-independent; until then, baking is the fix.

- **The MicroZed's PL status LED tracks this too.** `DONE` is asserted only when the PL is
  configured, so it now lights at boot. It stays lit across a runtime swap, and a blank
  boot (bitstream omitted from the bif) leaves it unlit — a free, instant read on whether
  the PL was configured at all.

Shipped fabrics today: `acq.bin` (128-ch), `aimuboth.bin` (64-ch/port + dual IMU),
`aimu_a.bin` / `aimu_b.bin` (one cable each way). The scan/detect fabric is retired —
`aimuboth` supersedes it, with the same I2C on both ports plus a routed UART.

## Build host (Vitis 2025.1) environment

`scripts/build_acq_loader.sh` builds the deferred image (BOOT.bin from src-core0 vs the
`acq_imu_both` superset .xsa, + the fabric `.bin`s). Two host env prerequisites, easy to
lose across a machine reboot (both surfaced as deterministic platform-gen failures):

- **`libtinfo.so.5`** — Vitis `hsi`/`sdtgen` needs ncurses5; modern distros ship `.so.6`.
  Symptom: `package require sdtgen FAILED` / `error loading hsi ... libtinfo.so.5`. Fix:
  `ln -s libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5` (or a user-dir symlink on
  `LD_LIBRARY_PATH`).
- **Vitis platform-creation race (worked around in-script; NO env var needed).** On the
  first `create_platform_component`, Vitis fires two concurrent `empyro repo -st` writes to
  the shared `vitis_workspace/_ide/.wsdata/.repo.yaml` while a domain's `empyro create_bsp`
  reads it, so it intermittently fails `[ERROR] Couldnt find the src directory for
  empty_application` / `zynq_fsbl` (see `vitis_workspace/_ide/logs/vitis.log` for the exact
  command timeline). The schema is complete afterward, so `scripts/create_vitis_project.py`
  recreates the platform on the settled schema (the scripted "run it twice") and it becomes
  deterministic. `ESW_REPO` is **not** needed — Vitis uses its bundled
  `Vitis/data/embeddedsw` repo regardless of that env var.

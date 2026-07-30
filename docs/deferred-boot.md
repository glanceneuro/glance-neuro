# Deferred-load / multi-bitstream boot (step 2)

Design note for the "network-first, then load a fabric" boot model. Step 1 (the
IMU detector, `docs/imu-detect.md`) proved I2C detection on a single baked-in
bitstream. Step 2 changes *how the PL gets loaded* so one SD image can bring up
whichever fabric the plugged-in headstages need — decided at runtime, after the
network is already up.

## Why it works

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
BootROM → FSBL: PS up (DDR, clocks, MIO Ethernet/SD/QSPI), load app ELF.   PL blank, pins Hi-Z (safe)
   app: lwIP up over MIO GEM  →  net.py makes contact                      still no PL
   app: read <name>.bin from SD (xilffs) → program PL via PCAP (XDcfg)
        → enable PS↔PL level shifters + release FPGA resets → re-init drivers
   app: probe / acquire through the just-loaded fabric
```

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

`blobs/` **is** the SD card image — its contents are copied verbatim to the FAT
root. `BOOT.bin` shrinks to **FSBL + orchestrator app ELF — no bitstream**, and
the fabrics live beside it as plain files:

| file | fabric | when |
|---|---|---|
| `detect.bin` | two I2C masters (step 1) | first load; also *is* the acquisition fabric whenever neither port is 128-ch |
| `acq_AA.bin` | both ports 128-ch (LVDS) | both ports high-channel |
| `acq_AN.bin` / `acq_NA.bin` | one port 128-ch, other 64-ch/IMU | mixed |

A collapse worth noting: the **detect image is the "both single-ended" image**,
which is also the running acquisition fabric for the common IMU/64-ch cases. So
the first load doubles as detector *and* as the streaming fabric; a PCAP swap to
an LVDS-bearing image is only needed when a port is actually 128-ch.

## Build & commit discipline (the load-bearing change)

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

## Orchestration (later increment)

Once loads are trusted, the app runs the state machine on its own: on boot (PL
blank) → `load detect.bin` → probe both ports (I2C CHIP_ID + high-Z level sense)
→ classify each port (128-ch / 64-ch+IMU / empty) → pick the matching
`acq_XX.bin` → load it → start acquisition. The host can also drive each step
explicitly for bring-up and testing.

## Increments

- **2a — deferred-load proof** *(done, validated on hardware)*: orchestrator app
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
- **No boot-time serial console on this board.** The console UART (UART1) is
  routed through the PL — EMIO to the FT230 on M14/M15 (`constraints/uart.xdc`),
  not MIO — so it only exists once a fabric that routes it is loaded. The blank-PL
  phase (FSBL → network → first `load_pl`) is therefore silent on serial by
  construction; use the network for status there. A fabric can route EMIO UART to
  M14/M15 for a post-load console (acquisition parity), but the early boot log
  needs another channel (e.g. a "boot log over TCP" command) if wanted.

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

Shipped fabrics today (coexist model, not the earlier `acq_AA/AN/NA` sketch above):
`acq.bin` (128-ch), `detect.bin` (scan), `aimuboth.bin` (64-ch/port + dual IMU).

## Build host (Vitis 2025.1) environment

`scripts/build_acq_loader.sh` builds the deferred image (BOOT.bin from src-core0 vs the
`acq_imu_both` superset .xsa, + the fabric `.bin`s). Two host env prerequisites, easy to
lose across a machine reboot (both surfaced as deterministic platform-gen failures):

- **`libtinfo.so.5`** — Vitis `hsi`/`sdtgen` needs ncurses5; modern distros ship `.so.6`.
  Symptom: `package require sdtgen FAILED` / `error loading hsi ... libtinfo.so.5`. Fix:
  `ln -s libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5` (or a user-dir symlink on
  `LD_LIBRARY_PATH`).
- **`ESW_REPO`** — must point at the complete embeddedsw repo so the FSBL/sw_apps
  resolve. Symptom: `[ERROR] Couldnt find the src directory for zynq_fsbl`. Fix:
  `export ESW_REPO=/opt/Xilinx/2025.1/data/embeddedsw`.

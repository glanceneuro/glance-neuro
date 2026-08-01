# Boot and fabric swapping

How the board comes up, what is on the SD card, and the rules that runtime PL
reconfiguration has to respect. The rules in "Rules paid for on the board" and "The
console is a PL-dependent resource" were each paid for on hardware; the rest is
reference.

## Boot flow

```
BootROM → FSBL: PS up (DDR, clocks, MIO Ethernet/SD/QSPI), CONFIGURE THE PL from the
                bitstream baked into BOOT.bin, load both core ELFs
   app: acq_pl_init_early() (CDMA + TLB) -- BEFORE the network
   app: lwIP up over MIO GEM → link → core 1 wakes → command server + beacon
   app: acq_pl_init_late() (the print-heavy register setup), pl_is_acq = 1
   app: host connects; set_config / rescan PCAP-swaps a fabric over the SETTLED link
        → level shifters + FPGA resets → re-init drivers → probe / acquire
```

**No PCAP runs at boot.** The FSBL configures the PL, which is the path `main` has
always shipped, and the runtime-PCAP rules below apply only to swaps made from the
live app. The console exists from the FSBL's first line only because the PL is
already configured by then: the debug UART leaves the chip through PL balls, so a
blank PL is silent.

The app is the **persistent orchestrator**: it lives in DDR/OCM and keeps running,
network up, across PL reconfigurations, so the host stays connected while the board
swaps fabrics under it.

## The SD card

`blobs/` **is** the SD card image — its contents are copied verbatim to the FAT root.
`BOOT.bin` carries **FSBL + the default acquisition bitstream + both core ELFs**, and
the swappable fabrics live beside it as plain files:

| file | fabric | when |
|---|---|---|
| `acq.bin` | both ports 128-ch LVDS, no I2C | no IMU on either cable; also the fabric baked into `BOOT.bin` |
| `aimuboth.bin` | both ports 64-ch + a BNO055 each | IMUs on both cables — and the fabric the IMU census runs on, being the only one with I2C on both ports |
| `aimu_a.bin` / `aimu_b.bin` | one port 64-ch + IMU, the other 128-ch LVDS | mixed |

**Fabric blob filenames must be 8.3 (≤8-char base).** The loader's xilffs is built
`FF_USE_LFN=0`, so `f_open("0:/<name>.bin")` fails `PL_ERR_OPEN` on a longer base name
even when the file is present. That is why `acq_imu_both.bin` ships as
**`aimuboth.bin`**. The host-facing config *name* (`net.py CONFIGS`) is unconstrained;
only the SD `file` in `pl_configs` must be 8.3.

Copying **only** `BOOT.bin` boots and streams, so it looks fine — but every fabric
swap then fails `PL_ERR_OPEN`, which reads as a firmware bug rather than a missing
file.

## Rules paid for on the board

**Do not PCAP-load a fabric near the GEM/PHY bring-up window.** Loading *before*
`lwip_init` left the MAC unable to transmit at all (zero frames, board unreachable);
loading *right after* link-up dropped the PHY (err −4). A load over a fully-settled
link — a host `set_config`, seconds later — is safe, and the link survives. This is
why reconfiguration is reachable only from a TCP command: by construction that
cannot happen until the network is long since up.

**`acq_pl_init_early()` must run before `lwip_init()`.** Empirical: moving it after
cost the link on hardware. The mechanism is *not* established, and one
plausible-sounding explanation is already ruled out — that `pl_dma_init()`'s
`Xil_SetTlbAttributes`, being 1 MB granular, reaches into lwIP's descriptor ring. It
does not: `pl_dma_lfp_staging` is at `0x00400000` and `pl_dma_staging` at
`0x00500000`, while `emac_bd_space` is at `0x00800000` — three different 1 MB
sections, no shared TLB entry. Don't re-derive that story; the real cause is still
unfound.

**Re-init every driver after a load.** Skipping the level-shifter/reset step is the
classic "loaded but the PL looks dead" failure. See the sequence under
*Implementation path*.

**Reconfiguration downtime is ~10s of ms** for a full 7z020 bitstream over PCAP.
Trivial between sessions; acquisition is down for it.

## The console is a PL-dependent resource

The debug UART is **UART1 on EMIO**, not MIO: `design_1_bd.tcl` sets
`PCW_UART1_UART1_IO {EMIO}` and brings `UART1_TX_0` / `UART1_RX_0` out as top-level
PL ports, which `constraints/uart.xdc` pins to **M14/M15** (JX2 → the FT230
USB-serial bridge). With no fabric configured those pins have no routing at all, so
every character — FSBL included — goes nowhere.

| PL state | console | why |
|---|---|---|
| blank (from power-on) | **no** | EMIO UART signals have no PL routing |
| mid-reprogram (PCAP in flight) | **no** | the PL is cleared, so the routing is gone until the new fabric configures |
| `acquisition`, `acq_imu_*` | yes | full constraint set includes `uart.xdc` |

This is why the bitstream is baked. An earlier revision booted with the PL blank and
paid for it: no console *and* no network meant a boot failure was invisible on both
channels, and the unlit DONE LED read as a dead board. Every fabric that still ships
routes the UART, so the only dark window left is the reprogram itself.

Writing to the UART while dark is **safe** — UART1 is a PS peripheral at
`0xE0001000`, always present, so the writes complete and only the bits on the wire
are lost. Nothing hangs. Serial *input* is gated across a swap for a different
reason: the RX ball floats while the PL is gone, and core 1 would otherwise parse the
noise as debug commands.

**The MicroZed's DONE LED tracks the same thing.** It is asserted only when the PL is
configured, so it lights at boot, drops for the moment of a runtime swap while the PL
is cleared and comes back as the new fabric configures, and stays dark if the
bitstream was ever omitted from the bif — a free, instant read on whether the PL came
up.

The lesson worth keeping: on this carrier the console is a PL-dependent resource, so
any future boot mode that leaves the PL blank silently gives up both serial
diagnostics and the DONE LED. A carrier respin could route the FT230 to MIO and make
the console genuinely PL-independent; until then, baking is the fix.

## Implementation path (Zynq-7000, verified against Vitis 2025.1)

- **PCAP programming: `XDcfg` (`devcfg_v3_8`), NOT XilFPGA.** XilFPGA in this
  toolchain is ZynqMP-only (all its interface code is under `.../zynqmp/`). The
  Zynq-7000 path is the classic device-config driver: `XDcfg_LookupConfig` →
  `XDcfg_CfgInitialize` → `XDcfg_Transfer`. The `ps7_dev_cfg_0` block is a fixed PS7
  peripheral, present regardless of BD config, so the driver always instantiates.
- **SD access: `xilffs` (FatFs).** In the app's BSP like `lwip220`; `f_mount` /
  `f_open` / `f_read` the bitstream into a DDR buffer.
- **Bitstream file format: PCAP `.bin`, not `.bit`.** `XDcfg_Transfer` wants a raw,
  byte-ordered bitstream with no `.bit` header. bootgen produces it:
  `bootgen -image <bif> -arch zynq -process_bitstream bin` → `<name>.bit.bin`. Ship
  that `.bin` on the SD FAT partition; never the raw `.bit`.
- **After every load — the FSBL-replacement sequence (easy to forget):**
  1. `XDcfg_Transfer` the bitstream, poll `XDcfg_IsDmaCommandDone` / PCAP done.
  2. **Enable PS↔PL level shifters** and **release the FPGA resets** via SLCR
     (`FPGA_RST_CTRL` 0xF8000240 → 0, `LVL_SHFTR_EN` 0xF8000900 → 0xF), with the SLCR
     unlock (0xF8000008 = 0xDF0D) around it.
  3. Re-assert/-release the design's `proc_sys_reset` and re-init every PL-facing
     driver (AXI regs, IIC, and — in acquisition — DMA).
- **Before reconfiguring a *running* fabric:** quiesce any PL AXI master (the
  acquisition CDMA) and stop streaming first, so nothing is mid-transaction when the
  fabric disappears.

## Build host (Vitis 2025.1) environment

Two prerequisites, easy to lose across a machine reboot — both surface as
deterministic platform-generation failures:

- **`libtinfo.so.5`** — Vitis `hsi`/`sdtgen` needs ncurses5; modern distros ship
  `.so.6`. Symptom: `package require sdtgen FAILED` / `error loading hsi ...
  libtinfo.so.5`. Fix: `ln -s libtinfo.so.6 /usr/lib/x86_64-linux-gnu/libtinfo.so.5`,
  or a user-dir symlink on `LD_LIBRARY_PATH`.
- **Vitis platform-creation race** (worked around in-script; no env var needed). On
  the first `create_platform_component`, Vitis fires two concurrent
  `empyro repo -st` writes to the shared `vitis_workspace/_ide/.wsdata/.repo.yaml`
  while a domain's `empyro create_bsp` reads it, so it intermittently fails
  `[ERROR] Couldnt find the src directory for empty_application` / `zynq_fsbl`. The
  schema is complete afterward, so `scripts/create_vitis_project.py` recreates the
  platform on the settled schema — the scripted "run it twice" — and it becomes
  deterministic. `ESW_REPO` is **not** needed; Vitis uses its bundled
  `Vitis/data/embeddedsw` repo regardless.

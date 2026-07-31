# IMU presence detector (step 1)

A standalone "detect" image that probes both headstage ports for a Bosch BNO055
over the shared 2nd-CIPO I2C lane and reports per-port via `net.py detect_imu`.
First validator for the IMU-movement project.

## Design

- **PL** (`programmable_logic/block_design/detect_bd.tcl`): a minimal PS7 (the
  acquisition config reused, so MIO Ethernet / DDR / SD all work) + **two Xilinx
  AXI IIC controllers** (`axi_iic`, one per port) on GP0. Their I2C pins are the
  2nd-CIPO pairs — **M19/M20 (port A), K16/J16 (port B)** — as `LVCMOS25`
  open-drain (bank 35, 2.5 V; the 2 kOhm pull-ups are on the headstage). The
  confirmed cable convention is **SDA on the -N pin, SCL on the -P pin** (M20=SDA
  / M19=SCL, J16=SDA / K16=SCL); see `detect_pins.xdc`. Bases: `axi_iic_a` at
  `0x43D00000`, `axi_iic_b` at `0x43D10000`.
- **Firmware** (`firmware/src-detect/`): a self-contained app — MIO-GEM network
  up plus the same 20-byte TCP protocol + discovery beacon so `net.py` connects
  unchanged — handling `PING` and `DETECT_IMU`. `pl_imu_detect.c` drives each
  controller with the **dynamic** low-level API — `XIic_DynInit` (soft-reset +
  enable the core), then `XIic_DynSend` of the CHIP_ID register pointer to 0x28
  with a repeated start, then `XIic_DynRecv` of one byte. The plain
  `XIic_Send`/`XIic_Recv` assume an already-initialized core and drove nothing;
  `XIic_DynInit` is required. It never touches acquisition PL (absent here; its
  AXI addresses would hang the core).
- **Host** (`remote/net.py detect_imu`, `CMD_DETECT_IMU=0xB0`, version "IMU2").
- **Build**: `scripts/build_detect.sh` -> `blobs/BOOT-detect.bin` (FSBL + detect
  bitstream + app), separate from the acquisition `BOOT.bin`.

### Why AXI IIC and not a custom master

The first cut used a hand-rolled bit-bang I2C master (`i2c_probe.sv`). It passed
an idealized testbench but failed on silicon — false ACKs on an empty bus, no ACK
on a real BNO055 — because a bit-bang master must lock to the actual line
transitions, not an internal phase counter, and the idealized sim slave hid the
mistiming. Replaced with the silicon-proven `axi_iic` IP, which handles real bus
timing and clock stretching.

Tradeoff: the custom design sensed idle line levels before driving (a safety
interlock against an LVDS-driving 128-ch headstage). With `axi_iic` owning the
pins, that pre-sense is gone; a transaction into an LVDS output just fails (no
ACK), a brief current-limited drive rather than a pre-checked no-drive. Re-add a
hardware pre-sense later if airtight safety on those pins is needed.

### Bring-up: two independent bugs, one diagnostic

The AXI-IIC version still read "nothing answered at 0x28" on every port and every
state — including a known-good BNO055. Two separate faults stacked:

1. **Uninitialized core.** `XIic_Send` was called with no prior init, so no
   transaction ever reached the bus. Fixed with `XIic_DynInit` (above).
2. **Reversed SDA/SCL.** With the core alive, a real IMU *still* did not ACK
   because the first pin-map guess had SDA and SCL swapped.

They were untangled by folding the core's **status register** (post-init) into
the reply as a diagnostic (`[31:24]`, printed by `net.py` as `iic_sr=`). A live
idle core reads `0xC0` (both FIFOs empty). Once `iic_sr=0xC0` showed on a
no-ACK port, the controller was proven working, so the fault had to be the
wiring — and the swapped pin map (now the default in `detect_pins.xdc`) ACKed
`chip_id=0xA0`. Keep the `iic_sr` byte: `0x00`/`0xFF` means the base address or
the core is wrong, which is a different failure from a device simply being absent.

## Result word (per port, in the CMD_DETECT_IMU reply)

`[0]` present (ACKed AND chip_id==0xA0) · `[1]` ack (device answered at 0x28) ·
`[15:8]` chip_id · `[31:24]` `iic_sr` (AXI IIC status register post-init,
diagnostic; a live idle core reads `0xC0`). Reply = `{result_a, result_b,
version}` (12 bytes).

## Bench test

1. Flash `blobs/BOOT-detect.bin` to the SD card **renamed to `BOOT.bin`** (back up
   the acquisition `BOOT.bin` first). Boot — network-only, static `192.168.18.10`.
   The debug UART is not routed in this image; use the network.
2. Host on `192.168.18.x/24`, then `python3 remote/net.py` -> `detect_imu`.
3. Expect, e.g. (IMU headstage on port A):
   ```
   Port A: IMU present (BNO055, chip_id=0xA0) [iic_sr=0xC0, controller alive]
   Port B: no IMU (nothing answered at 0x28) [iic_sr=0xC0, controller alive]
   ```
   Swap headstages between ports; confirm it tracks. `iic_sr=0xC0` on both ports
   means the controllers are alive regardless of whether a device answers.
4. Knobs if needed: SDA/SCL-vs-pin is confirmed (see `detect_pins.xdc`) — if a
   future headstage revision reverses it, swap the two `PACKAGE_PIN` lines for
   that port and rebuild; I2C rate (`IIC_FREQ_KHZ` on the `axi_iic` cells in
   `detect_bd.tcl`, currently 100 kHz).
5. Restore the acquisition `BOOT.bin` when done.

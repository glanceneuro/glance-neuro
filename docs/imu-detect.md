# IMU presence detector (step 1) — status & build recipe

A standalone "detect" bitstream + minimal app that probes both headstage ports
for a Bosch BNO055 over the shared 2nd-CIPO I2C lane and reports per-port via
`net.py detect_imu`. First validator for the IMU-movement project; see
`../../scratch` research notes for the full plan.

## Done & verified (sim)

| piece | what | status |
|---|---|---|
| `programmable_logic/src/i2c_probe.sv` | safe, clock-stretch-aware BNO055 presence probe (high-Z sense → CHIP_ID read) | **sim PASS** (`run_i2c_probe_tb.sh`) |
| `programmable_logic/src/imu_detect_top.sv` | AXI-Lite wrapper, 2 probes (port A/B), open-drain IOBUFs, per-port RESULT regs | **sim PASS** (`run_imu_detect_tb.sh`) |
| `programmable_logic/sim/i2c_slave_model.sv` | reusable behavioral BNO055 slave | — |
| `programmable_logic/constraints/detect_pins.xdc` | M19/M20 (A), K16/J16 (B) → LVCMOS25 SDA/SCL | written |
| `firmware/src-detect/pl_imu_detect.{c,h}` | AXI driver: start, poll done, read results | written |
| `remote/net.py` `detect_imu` + `CMD_DETECT_IMU=0xB0` | host command + per-port decode | syntax/decode checked |

The probe is verified for: IMU present (0xA0), device-with-wrong-ID, absent
device, non-IMU headstage (idle not both-high → **never drives**, the safety
interlock), and clock stretching.

## Register map — `imu_detect_top` (AXI-Lite base 0x43D0_0000)

| off | reg | bits |
|---:|---|---|
| 0x00 | CONTROL W1P | [0] start |
| 0x04 | STATUS RO | [0] busy [1] done |
| 0x08 | RESULT_A RO | [0] present [1] ack [2] timeout [4:3] idle{scl,sda} [15:8] chip_id |
| 0x0C | RESULT_B RO | same |
| 0x10 | VERSION RO | 0x494D5531 "IMU1" |

## Remaining — the parallel "detect" build (hardware-loop step)

This is the part that needs a build on the real toolchain + your board to trust;
it's mechanical but un-simulatable here. Recommended shape (mode-parameterised so
the acquisition flow is untouched):

1. **Detect block design** `programmable_logic/block_design/detect_bd.tcl`:
   the SAME PS7 config as `design_1_bd.tcl` (copy it verbatim — Ethernet MIO,
   DDR, clocks, SD), one `smartconnect` (NUM_MI=1) on `M_AXI_GP0` →
   `imu_detect_top/s_axi`, `assign_bd_address 0x43C00000-clean base` (use
   0x43D00000 to match the driver), and `sda_a/scl_a/sda_b/scl_b` as external
   inout ports. No data_generator / BRAM / CDMA / LFP / stim / LVDS buffers.
2. **`scripts/create_vivado_project.tcl`**: take a `mode` tclarg
   (`acquire`|`detect`) selecting which BD to source, which constraints
   (`detect_pins.xdc` instead of `intan_io.xdc`), and the wrapper top.
3. **`scripts/create_vitis_project.py`**: a `klab-detect` app on core 0 that
   imports `firmware/src-detect` + `src-shared` + `include`, reusing the lwIP
   platform config. Its `main`: platform init → lwIP up (MIO GEM) → TCP server
   → dispatch `PING` + `CMD_DETECT_IMU` (calls `pl_imu_detect_run`, replies the
   12-byte struct). Reuse the network/command scaffolding from `src-core0`
   (factor the lwIP+TCP setup out of the acquisition-coupled `main.c`), no
   acquisition loop, no core-1 app needed.
4. **`scripts/boot.bif`** (detect): FSBL + detect `.bit` + `klab-detect.elf`.
5. **`scripts/build.sh`**: a `--detect` target producing
   `blobs/BOOT-detect.bin` from the detect BD + detect app, keeping the
   acquisition `BOOT.bin` path unchanged. Both blobs are built from the same
   source per the commit-discipline rule.

## Bench test procedure (with the board + both headstages)

1. Flash `BOOT-detect.bin`; the board comes up on the network with no
   acquisition fabric.
2. `python3 remote/net.py` → connect → `detect_imu`.
3. Expect, e.g.:
   ```
   Port A: IMU present (BNO055, chip_id=0xA0)
   Port B: no IMU -- lines not both-high (idle scl,sda=10) -- LVDS/absent headstage, did not probe
   ```
4. Swap headstages between ports; confirm the verdict tracks the hardware.
5. Tune if needed: I2C speed (`I2C_HZ` param) for long cables, and confirm the
   SDA/SCL-vs-pin assignment in `detect_pins.xdc` matches the real cable.

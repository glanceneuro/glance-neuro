#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# Build the DEFERRED-LOAD ACQUISITION image (step 2c, docs/deferred-boot.md).
# blobs/ is the SD card image -- copy its contents verbatim to the FAT root:
#   - blobs/BOOT.bin          : FSBL + both core ELFs, NO bitstream (PL blank at boot)
#   - blobs/acq.bin           : 128-ch LVDS acquisition fabric (no IMU)
#   - blobs/detect.bin        : single-ended I2C-probe fabric (both AXI IICs)
#   - blobs/aimuboth.bin      : 64-ch/port acquisition + BNO055 on both cables
#                               (8.3 short name -- xilffs FF_USE_LFN=0 on the loader)
#
# The firmware is built against the acq_imu_both .xsa (the SUPERSET: CDMA + both
# AXI IICs), so its BSP carries XIic and pl_imu_detect.c links -- core0 then
# probes IMUs on any loaded fabric that has the IICs (acq_imu_both or detect),
# gated by pl_has_iic. The core acq peripherals sit at the same addresses in the
# plain acq and acq_imu_both fabrics, so the firmware drives all three unchanged.
#
# Boot flow: PL blank -> net.py connects -> set_config <acquisition|scan|
# acq_imu_both> PCAP-loads the chosen fabric -> stream / detect_imu.
#
#   scripts/build_acq_loader.sh            # fabrics (reuse or build) + apps + BOOT.bin + *.bin
#   scripts/build_acq_loader.sh --app-only # reuse existing bitstreams, rebuild apps only
set -euo pipefail
XILINX_ROOT="${XILINX_ROOT:-/opt/Xilinx/2025.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
die() { echo "" >&2; echo "ACQ-LOADER BUILD FAILED: $*" >&2; exit 1; }

app_only=0
[ "${1:-}" = "--app-only" ] && app_only=1

# 128-ch acquisition fabric (source of acq.bin)
XSA=vivado_project/klab_project.xsa
BIT=vivado_project/klab_project.runs/impl_1/design_1_wrapper.bit
TIMING=vivado_project/klab_project.runs/impl_1/design_1_wrapper_timing_summary_routed.rpt

# acq_imu_both fabric (firmware platform .xsa + source of acq_imu_both.bin). It
# runs a post-route phys_opt hold-fix pass, so the authoritative timing verdict is
# the post-phys_opt report, not the route report.
IMU_XSA=vivado_acq_imu_both/acq_imu_both.xsa
IMU_BIT=vivado_acq_imu_both/acq_imu_both_project.runs/impl_1/design_1_wrapper.bit
IMU_TIMING=vivado_acq_imu_both/acq_imu_both_project.runs/impl_1/design_1_wrapper_timing_summary_postroute_physopted.rpt

echo "== [1/5] PL: acquisition (128-ch) + acq_imu_both fabrics =="
# Source Vivado only if at least one fabric actually needs synthesis.
if [ "$app_only" != 1 ] && { ! { [ -f "$XSA" ] && [ -f "$BIT" ]; } || ! { [ -f "$IMU_XSA" ] && [ -f "$IMU_BIT" ]; }; }; then
  # shellcheck disable=SC1091
  source "$XILINX_ROOT/Vivado/settings64.sh"
fi

# --- 128-ch acquisition fabric ---
if [ -f "$XSA" ] && [ -f "$BIT" ]; then
  echo "   acq (128-ch): reusing existing bitstream"
elif [ "$app_only" = 1 ]; then
  die "no acquisition bitstream -- run scripts/build.sh once first"
else
  echo "   acq (128-ch): synthesis + implementation (~18 min)"
  rm -rf vivado_project
  vivado -mode batch -nojournal -log vivado_create.log -source scripts/create_vivado_project.tcl >/dev/null \
    || die "acq (128-ch) project creation failed (see vivado_create.log)"
  vivado -mode batch -nojournal -log vivado_build.log -source scripts/build_bitstream.tcl >/dev/null \
    || die "acq (128-ch) bitstream build failed (see vivado_build.log)"
  [ -f "$BIT" ] || die "acq (128-ch) implementation produced no bitstream"
fi
[ ! -f "$TIMING" ] || grep -q "All user specified timing constraints are met" "$TIMING" \
  || die "acq (128-ch) bitstream TIMING NOT MET"

# --- acq_imu_both fabric (also the firmware platform) ---
if [ -f "$IMU_XSA" ] && [ -f "$IMU_BIT" ]; then
  echo "   acq_imu_both: reusing existing bitstream"
elif [ "$app_only" = 1 ]; then
  die "no acq_imu_both bitstream -- run 'vivado -mode batch -source scripts/acq_imu_both_build.tcl' once first"
else
  echo "   acq_imu_both: synthesis + implementation (~18 min)"
  rm -rf vivado_acq_imu_both
  vivado -mode batch -nojournal -log vivado_acq_imu_both_build.log -source scripts/acq_imu_both_build.tcl >/dev/null \
    || die "acq_imu_both build failed (see vivado_acq_imu_both_build.log)"
  [ -f "$IMU_BIT" ] || die "acq_imu_both implementation produced no bitstream"
fi
[ -f "$IMU_TIMING" ] && grep -q "All user specified timing constraints are met" "$IMU_TIMING" \
  || die "acq_imu_both bitstream TIMING NOT MET (or post-phys_opt report missing)"

echo "== [2/5] Vitis: platform (acq_imu_both.xsa -> XIic) + both apps =="
# shellcheck disable=SC1091
source "$XILINX_ROOT/Vitis/settings64.sh"
export KLAB_XSA="$IMU_XSA"     # build the firmware BSP against the superset .xsa
vitis_ok=0
for attempt in 1 2 3; do
  rm -rf vitis_workspace .Xil
  if vitis -s scripts/create_vitis_project.py > "vitis_attempt${attempt}.log" 2>&1; then
    vitis_ok=1; [ "$attempt" -gt 1 ] && echo "   (succeeded on attempt $attempt)"; rm -f vitis_attempt*.log; break
  fi
  echo "   attempt $attempt failed, retrying..." >&2
done
[ "$vitis_ok" = 1 ] || die "Vitis build failed 3 times (see vitis_attempt*.log)"
[ -f vitis_workspace/klab-firmware/build/klab-firmware.elf ] || die "core0 ELF not produced"
[ -f vitis_workspace/klab-firmware-core1/build/klab-firmware-core1.elf ] || die "core1 ELF not produced"

echo "== [3/5] BOOT.bin (FSBL + both ELFs, no bitstream) =="
bootgen -image scripts/boot_acq_loader.bif -arch zynq -o BOOT.bin -w >/dev/null \
  || die "bootgen (BOOT.bin) failed"
mkdir -p blobs && mv -f BOOT.bin blobs/BOOT.bin

echo "== [4/5] fabrics for SD: acq.bin + detect.bin + aimuboth.bin =="
# -process_bitstream bin strips the .bit header and byte-orders the data for
# XDcfg/PCAP, emitting <name>.bit.bin next to the input.
bit_to_pcap() {  # <src.bit> <dst blobs/name.bin>
  local bit="$1" dst="$2"
  [ -f "$bit" ] || die "bitstream .bit not found ($bit)"
  printf 'all:\n{\n\t%s\n}\n' "$bit" > .pcap.bif
  bootgen -image .pcap.bif -arch zynq -process_bitstream bin -w >/dev/null \
    || die "bootgen -process_bitstream failed for $bit"
  rm -f .pcap.bif
  cp -f "${bit}.bin" "$dst"
}
bit_to_pcap "$BIT" blobs/acq.bin
bit_to_pcap "vivado_detect/detect_project.runs/impl_1/detect_bd_wrapper.bit" blobs/detect.bin
# 8.3 short name: the loader's xilffs has FF_USE_LFN=0, so the SD filename base
# must be <=8 chars. "acq_imu_both.bin" (12-char base) fails f_open; use aimuboth.
bit_to_pcap "$IMU_BIT" blobs/aimuboth.bin

echo "== [5/5] done =="
echo ""
echo "   blobs/ is the SD image -- copy its contents verbatim to the SD FAT root:"
echo "   boot        : blobs/BOOT.bin         ($(stat -c%s blobs/BOOT.bin) bytes, md5 $(md5sum blobs/BOOT.bin | cut -c1-32))"
echo "   acq (128ch) : blobs/acq.bin          ($(stat -c%s blobs/acq.bin) bytes, md5 $(md5sum blobs/acq.bin | cut -c1-32))"
echo "   scan/detect : blobs/detect.bin       ($(stat -c%s blobs/detect.bin) bytes, md5 $(md5sum blobs/detect.bin | cut -c1-32))"
echo "   acq+IMU     : blobs/aimuboth.bin      ($(stat -c%s blobs/aimuboth.bin) bytes, md5 $(md5sum blobs/aimuboth.bin | cut -c1-32))"
echo "   test        : cp blobs/* -> SD root; boot (PL blank) -> net.py ->"
echo "                 set_config acq_imu_both -> detect_imu (both cables) / stream"

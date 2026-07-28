#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# Build the standalone IMU-DETECT image -> blobs/BOOT-detect.bin.
# Separate from build.sh (the acquisition BOOT.bin): the shared 2nd-CIPO pins
# are single-ended I2C here and LVDS there, so it is a distinct bitstream + a
# minimal firmware. Flash BOOT-detect.bin, then: net.py -> detect_imu.
#
#   scripts/build_detect.sh            # build PL + app + BOOT-detect.bin
#   scripts/build_detect.sh --app-only # skip the ~10 min PL build, reuse the XSA
set -euo pipefail
XILINX_ROOT="${XILINX_ROOT:-/opt/Xilinx/2025.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
die() { echo "" >&2; echo "DETECT BUILD FAILED: $*" >&2; exit 1; }

app_only=0
[ "${1:-}" = "--app-only" ] && app_only=1
OUT="blobs/BOOT-detect.bin"

if [ "$app_only" = 0 ]; then
  echo "== [1/3] PL: detect bitstream (~10 min) =="
  # shellcheck disable=SC1091
  source "$XILINX_ROOT/Vivado/settings64.sh"
  rm -rf vivado_detect
  vivado -mode batch -nojournal -log vivado_detect_build.log -source scripts/detect_build.tcl >/dev/null \
    || die "Vivado detect build failed (see vivado_detect_build.log)"
  grep -q "All user specified timing constraints are met" \
    vivado_detect/detect_project.runs/impl_1/detect_bd_wrapper_timing_summary_routed.rpt \
    || die "detect bitstream TIMING NOT MET"
else
  echo "== [1/3] PL: reusing existing detect XSA =="
  [ -f vivado_detect/detect_project.xsa ] || die "no detect XSA -- run without --app-only first"
fi

echo "== [2/3] Vitis: detect platform + app =="
# shellcheck disable=SC1091
source "$XILINX_ROOT/Vitis/settings64.sh"
rm -rf vitis_detect .Xil
vitis -s scripts/create_detect_vitis.py > vitis_detect_build.log 2>&1 \
  || die "Vitis detect build failed (see vitis_detect_build.log)"
[ -f vitis_detect/klab-detect/build/klab-detect.elf ] || die "detect app ELF not produced"

echo "== [3/3] $(basename "$OUT") =="
bootgen -image scripts/boot_detect.bif -arch zynq -o BOOT-detect.bin -w >/dev/null \
  || die "bootgen failed"
mkdir -p blobs && mv -f BOOT-detect.bin "$OUT"

echo ""
echo "   image : $OUT ($(stat -c%s "$OUT") bytes, md5 $(md5sum "$OUT" | cut -c1-32))"
echo "   test  : flash to SD, boot, then  python3 remote/net.py  ->  detect_imu"

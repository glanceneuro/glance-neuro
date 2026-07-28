#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# Build the DEFERRED-LOAD image (step 2, docs/deferred-boot.md):
#   - blobs/BOOT-loader.bin : FSBL + orchestrator app, NO bitstream (PL blank at boot)
#   - blobs/detect.bin      : the detect fabric as a PCAP bitstream, for the SD card
#
# The app is the same src-detect app as the detect image (it now also carries the
# PCAP loader + CMD_LOAD_PL); only the boot packaging differs. To test:
#   copy BOTH files to the SD FAT root, BOOT-loader.bin renamed to BOOT.bin.
#   boot (PL blank) -> net.py connects -> load_pl detect -> detect_imu.
#
#   scripts/build_loader.sh            # PL XSA + app + BOOT-loader.bin + detect.bin
#   scripts/build_loader.sh --app-only # reuse existing detect XSA (skip ~10 min PL)
set -euo pipefail
XILINX_ROOT="${XILINX_ROOT:-/opt/Xilinx/2025.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
die() { echo "" >&2; echo "LOADER BUILD FAILED: $*" >&2; exit 1; }

app_only=0
[ "${1:-}" = "--app-only" ] && app_only=1

if [ "$app_only" = 0 ]; then
  echo "== [1/4] PL: detect bitstream (~10 min) =="
  # shellcheck disable=SC1091
  source "$XILINX_ROOT/Vivado/settings64.sh"
  rm -rf vivado_detect
  vivado -mode batch -nojournal -log vivado_detect_build.log -source scripts/detect_build.tcl >/dev/null \
    || die "Vivado detect build failed (see vivado_detect_build.log)"
  grep -q "All user specified timing constraints are met" \
    vivado_detect/detect_project.runs/impl_1/detect_bd_wrapper_timing_summary_routed.rpt \
    || die "detect bitstream TIMING NOT MET"
else
  echo "== [1/4] PL: reusing existing detect XSA =="
  [ -f vivado_detect/detect_project.xsa ] || die "no detect XSA -- run without --app-only first"
fi

echo "== [2/4] Vitis: platform + orchestrator app (lwip + xilffs + devcfg) =="
# shellcheck disable=SC1091
source "$XILINX_ROOT/Vitis/settings64.sh"
rm -rf vitis_detect .Xil
vitis -s scripts/create_detect_vitis.py > vitis_detect_build.log 2>&1 \
  || die "Vitis build failed (see vitis_detect_build.log)"
[ -f vitis_detect/klab-detect/build/klab-detect.elf ] || die "app ELF not produced"

echo "== [3/4] BOOT-loader.bin (FSBL + app, no bitstream) =="
bootgen -image scripts/boot_loader.bif -arch zynq -o BOOT-loader.bin -w >/dev/null \
  || die "bootgen (BOOT-loader) failed"
mkdir -p blobs && mv -f BOOT-loader.bin blobs/BOOT-loader.bin

echo "== [4/4] detect.bin (PCAP bitstream for SD) =="
BIT="vivado_detect/detect_project.runs/impl_1/detect_bd_wrapper.bit"
[ -f "$BIT" ] || die "detect bitstream .bit not found ($BIT)"
# bootgen -process_bitstream bin strips the .bit header and byte-orders the data
# for XDcfg/PCAP, emitting <name>.bit.bin next to the input.
printf 'all:\n{\n\t%s\n}\n' "$BIT" > .detect_bit.bif
bootgen -image .detect_bit.bif -arch zynq -process_bitstream bin -w >/dev/null \
  || die "bootgen -process_bitstream failed"
rm -f .detect_bit.bif
PCAP_BIN="${BIT}.bin"
[ -f "$PCAP_BIN" ] || PCAP_BIN="$(dirname "$BIT")/$(basename "$BIT" .bit).bit.bin"
[ -f "$PCAP_BIN" ] || die "PCAP .bin not produced (looked for ${BIT}.bin)"
cp -f "$PCAP_BIN" blobs/detect.bin

echo ""
echo "   image  : blobs/BOOT-loader.bin ($(stat -c%s blobs/BOOT-loader.bin) bytes, md5 $(md5sum blobs/BOOT-loader.bin | cut -c1-32))"
echo "   fabric : blobs/detect.bin      ($(stat -c%s blobs/detect.bin) bytes, md5 $(md5sum blobs/detect.bin | cut -c1-32))"
echo "   test   : SD FAT root gets BOTH -- BOOT-loader.bin AS BOOT.bin, plus detect.bin."
echo "            boot (PL blank) -> net.py -> load_pl detect -> detect_imu"

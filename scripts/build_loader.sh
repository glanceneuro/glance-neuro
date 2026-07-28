#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# Build the DEFERRED-LOAD image (step 2, docs/deferred-boot.md). blobs/ is the SD
# card image -- copy its contents verbatim to the FAT root:
#   - blobs/BOOT.bin   : FSBL + orchestrator app, NO bitstream (PL blank at boot)
#   - blobs/detect.bin : the detect fabric as a PCAP bitstream, loaded at runtime
#
# The app is the same src-detect app as the detect image (it now also carries the
# PCAP loader + CMD_LOAD_PL); only the boot packaging differs. To test:
#   cp blobs/* -> SD FAT root (BOOT.bin is already named as the BootROM requires).
#   boot (PL blank) -> net.py connects -> load_pl detect -> detect_imu.
#
#   scripts/build_loader.sh            # PL XSA + app + BOOT.bin + detect.bin
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

echo "== [3/4] BOOT.bin (FSBL + app, no bitstream) =="
bootgen -image scripts/boot_loader.bif -arch zynq -o BOOT.bin -w >/dev/null \
  || die "bootgen (BOOT.bin) failed"
mkdir -p blobs && mv -f BOOT.bin blobs/BOOT.bin

# bootgen -process_bitstream bin strips the .bit header and byte-orders the data
# for XDcfg/PCAP, emitting <name>.bit.bin next to the input.
bit_to_pcap() {  # <src.bit> <dst blobs/name.bin>
  local bit="$1" dst="$2"
  [ -f "$bit" ] || die "bitstream .bit not found ($bit)"
  printf 'all:\n{\n\t%s\n}\n' "$bit" > .pcap.bif
  bootgen -image .pcap.bif -arch zynq -process_bitstream bin -w >/dev/null \
    || die "bootgen -process_bitstream failed for $bit"
  rm -f .pcap.bif
  cp -f "${bit}.bin" "$dst"
}

echo "== [4/4] fabrics for SD: detect.bin + acq.bin =="
bit_to_pcap "vivado_detect/detect_project.runs/impl_1/detect_bd_wrapper.bit" blobs/detect.bin
# acq.bin is the full acquisition fabric (big) -- the runtime-swap test's payload.
# Reuses the acquisition bitstream from scripts/build.sh (run it once if missing).
bit_to_pcap "vivado_project/klab_project.runs/impl_1/design_1_wrapper.bit" blobs/acq.bin

echo ""
echo "   blobs/ is the SD image -- copy its contents verbatim to the SD FAT root:"
echo "   boot   : blobs/BOOT.bin   ($(stat -c%s blobs/BOOT.bin) bytes, md5 $(md5sum blobs/BOOT.bin | cut -c1-32))"
echo "   fabric : blobs/detect.bin ($(stat -c%s blobs/detect.bin) bytes) + blobs/acq.bin ($(stat -c%s blobs/acq.bin) bytes)"
echo "   test   : cp blobs/* -> SD root; boot -> net.py -> load_pl detect / load_pl acq (swap), watch link"

#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# Build the DEFERRED-LOAD ACQUISITION image (step 2c, docs/deferred-boot.md).
# blobs/ is the SD card image -- copy its contents verbatim to the FAT root:
#   - blobs/BOOT.bin : FSBL + both core ELFs, NO bitstream (PL blank at boot)
#   - blobs/acq.bin  : the acquisition fabric as a PCAP bitstream, loaded at runtime
#
# Same acquisition firmware as build.sh, but core0 now boots network-first and
# PCAP-loads its own fabric from SD before any PL-touching init. To test:
#   cp blobs/* -> SD FAT root; boot (PL blank) -> net.py connects -> core0
#   auto-loads acq.bin -> stream as usual.
#
#   scripts/build_acq_loader.sh            # PL (reuse or build) + apps + BOOT.bin + acq.bin
#   scripts/build_acq_loader.sh --app-only # reuse the existing acquisition bitstream
set -euo pipefail
XILINX_ROOT="${XILINX_ROOT:-/opt/Xilinx/2025.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
die() { echo "" >&2; echo "ACQ-LOADER BUILD FAILED: $*" >&2; exit 1; }

app_only=0
[ "${1:-}" = "--app-only" ] && app_only=1

XSA=vivado_project/klab_project.xsa
BIT=vivado_project/klab_project.runs/impl_1/design_1_wrapper.bit
TIMING=vivado_project/klab_project.runs/impl_1/design_1_wrapper_timing_summary_routed.rpt

if [ "$app_only" = 1 ] || { [ -f "$XSA" ] && [ -f "$BIT" ]; }; then
  echo "== [1/4] PL: reusing the existing acquisition bitstream =="
  [ -f "$XSA" ] && [ -f "$BIT" ] || die "no acquisition bitstream -- run scripts/build.sh once first"
else
  echo "== [1/4] PL: acquisition synthesis + implementation (~18 min) =="
  # shellcheck disable=SC1091
  source "$XILINX_ROOT/Vivado/settings64.sh"
  rm -rf vivado_project
  vivado -mode batch -nojournal -log vivado_create.log -source scripts/create_vivado_project.tcl >/dev/null \
    || die "Vivado project creation failed (see vivado_create.log)"
  vivado -mode batch -nojournal -log vivado_build.log -source scripts/build_bitstream.tcl >/dev/null \
    || die "bitstream build failed (see vivado_build.log)"
  [ -f "$BIT" ] || die "implementation produced no bitstream"
fi
if [ -f "$TIMING" ]; then
  grep -q "All user specified timing constraints are met" "$TIMING" || die "acquisition bitstream TIMING NOT MET"
fi

echo "== [2/4] Vitis: platform + both apps (core0 now has xilffs + PCAP loader) =="
# shellcheck disable=SC1091
source "$XILINX_ROOT/Vitis/settings64.sh"
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

echo "== [3/4] BOOT.bin (FSBL + both ELFs, no bitstream) =="
bootgen -image scripts/boot_acq_loader.bif -arch zynq -o BOOT.bin -w >/dev/null \
  || die "bootgen (BOOT.bin) failed"
mkdir -p blobs && mv -f BOOT.bin blobs/BOOT.bin

echo "== [4/4] acq.bin (PCAP bitstream for SD) =="
# -process_bitstream bin strips the .bit header and byte-orders the data for
# XDcfg/PCAP, emitting <name>.bit.bin next to the input.
printf 'all:\n{\n\t%s\n}\n' "$BIT" > .acq_bit.bif
bootgen -image .acq_bit.bif -arch zynq -process_bitstream bin -w >/dev/null \
  || die "bootgen -process_bitstream failed"
rm -f .acq_bit.bif
PCAP_BIN="${BIT}.bin"
[ -f "$PCAP_BIN" ] || die "PCAP .bin not produced (looked for ${BIT}.bin)"
cp -f "$PCAP_BIN" blobs/acq.bin

echo ""
echo "   blobs/ is the SD image -- copy its contents verbatim to the SD FAT root:"
echo "   boot   : blobs/BOOT.bin ($(stat -c%s blobs/BOOT.bin) bytes, md5 $(md5sum blobs/BOOT.bin | cut -c1-32))"
echo "   fabric : blobs/acq.bin  ($(stat -c%s blobs/acq.bin) bytes, md5 $(md5sum blobs/acq.bin | cut -c1-32))"
echo "   test   : cp blobs/* -> SD root; boot (PL blank) -> net.py -> core0 auto-loads acq -> stream"

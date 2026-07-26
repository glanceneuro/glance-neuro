#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# The only way to build BOOT.bin.
#
# Produces blobs/BOOT.bin from the current tree and refuses to produce one it
# cannot vouch for. It decides for itself whether the PL needs re-synthesising by
# fingerprinting the sources, so a firmware-only edit costs ~3 minutes and a PL
# edit costs ~18 -- without anyone having to remember which they made.
#
#   scripts/build.sh              # build what needs building, then verify
#   scripts/build.sh --force-pl   # re-synthesise the PL even if unchanged
#   scripts/build.sh --check      # report what WOULD be rebuilt, change nothing
#
# Set XILINX_ROOT if the tools are not at /opt/Xilinx/2025.1.
set -euo pipefail

XILINX_ROOT="${XILINX_ROOT:-/opt/Xilinx/2025.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XSA=vivado_project/klab_project.xsa
STAMP=vivado_project/.pl_fingerprint
IMPL_BIT=vivado_project/klab_project.runs/impl_1/design_1_wrapper.bit
WS_BIT=vitis_workspace/klab-firmware/_ide/bitstream/klab_project.bit
TIMING=vivado_project/klab_project.runs/impl_1/design_1_wrapper_timing_summary_routed.rpt

force_pl=0; check_only=0
for a in "$@"; do
  case "$a" in
    --force-pl) force_pl=1 ;;
    --check)    check_only=1 ;;
    -h|--help)  sed -n '5,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

die() { echo "" >&2; echo "BUILD FAILED: $*" >&2; exit 1; }

# --- Does the PL need re-synthesising? ---------------------------------------
# Fingerprint every input the bitstream is built from. Anything that can change
# the fabric belongs here; the block design and the custom IP are build inputs
# just as much as the RTL is, and are the easiest to forget.
pl_fingerprint() {
  find programmable_logic/src programmable_logic/constraints \
       programmable_logic/block_design programmable_logic/ip \
       scripts/create_vivado_project.tcl scripts/build_bitstream.tcl \
       -type f 2>/dev/null | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1
}

fp="$(pl_fingerprint)"
need_pl=0
if [ ! -f "$XSA" ] || [ ! -f "$IMPL_BIT" ]; then
  need_pl=1; why="no bitstream yet"
elif [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$fp" ]; then
  need_pl=1; why="PL sources changed since the last bitstream"
elif [ "$force_pl" = 1 ]; then
  need_pl=1; why="--force-pl"
else
  why="PL sources unchanged"
fi

echo "== plan =="
echo "   PL   : $([ "$need_pl" = 1 ] && echo 'REBUILD' || echo 'reuse') ($why)"
echo "   Vitis: REBUILD (always -- the platform must follow the current .xsa)"
[ "$check_only" = 1 ] && exit 0

# --- PL ----------------------------------------------------------------------
if [ "$need_pl" = 1 ]; then
  echo "== [1/4] PL: synthesis + implementation + bitstream (~15 min) =="
  # shellcheck disable=SC1091
  source "$XILINX_ROOT/Vivado/settings64.sh"
  rm -rf vivado_project
  vivado -mode batch -nojournal -log vivado_create.log \
         -source scripts/create_vivado_project.tcl >/dev/null \
    || die "Vivado project creation failed (see vivado_create.log)"
  vivado -mode batch -nojournal -log vivado_build.log \
         -source scripts/build_bitstream.tcl >/dev/null \
    || die "bitstream build failed (see vivado_build.log)"
  [ -f "$IMPL_BIT" ] || die "implementation produced no bitstream"
  echo "$fp" > "$STAMP"
else
  echo "== [1/4] PL: reusing the existing bitstream =="
fi

# --- Vitis -------------------------------------------------------------------
# Always from scratch, against the current .xsa. Reusing a workspace is how a
# stale platform (and a stale bitstream copy) reaches BOOT.bin, and regenerating
# costs only a couple of minutes.
echo "== [2/4] Vitis: platform + both firmware apps, from the current .xsa =="
# shellcheck disable=SC1091
source "$XILINX_ROOT/Vitis/settings64.sh"
# Platform creation is intermittently racy: the domain is reported created and the
# very next get_domain call can still be told it does not exist. It is transient,
# so retry from a clean workspace rather than failing a 15-minute build on it.
vitis_ok=0
for attempt in 1 2 3; do
  rm -rf vitis_workspace .Xil
  if vitis -s scripts/create_vitis_project.py > "vitis_attempt${attempt}.log" 2>&1; then
    vitis_ok=1
    [ "$attempt" -gt 1 ] && echo "   (succeeded on attempt $attempt)"
    rm -f vitis_attempt*.log
    break
  fi
  echo "   attempt $attempt failed, retrying..." >&2
done
[ "$vitis_ok" = 1 ] || die "Vitis workspace/app build failed 3 times (see vitis_attempt*.log)"

# --- Bitstream staging -------------------------------------------------------
# boot.bif packs the workspace COPY, not implementation output. Stage it, then
# prove they match rather than assume it.
echo "== [3/4] staging the bitstream boot.bif will pack =="
mkdir -p "$(dirname "$WS_BIT")"
cp "$IMPL_BIT" "$WS_BIT"
cmp -s "$IMPL_BIT" "$WS_BIT" || die "staged bitstream does not match implementation output"

echo "== [4/4] BOOT.bin =="
bootgen -image scripts/boot.bif -arch zynq -o BOOT.bin -w >/dev/null \
  || die "bootgen failed"
mkdir -p blobs && mv -f BOOT.bin blobs/BOOT.bin

# --- Verification ------------------------------------------------------------
# Report the numbers. A build that cannot show these is not finished.
echo ""
echo "== verification =="

if [ -f "$TIMING" ]; then
  if grep -q "All user specified timing constraints are met" "$TIMING"; then
    wns=$(awk '/^ *WNS\(ns\)/{getline; getline; print $1; exit}' "$TIMING")
    echo "   timing   : MET (WNS ${wns:-?} ns, 0 failing endpoints)"
  else
    die "TIMING NOT MET -- see $TIMING. Do not ship this image."
  fi
else
  echo "   timing   : report missing (PL was reused; timing unchanged from that build)"
fi

cmp -s "$IMPL_BIT" "$WS_BIT" \
  && echo "   bitstream: BOOT.bin carries the fabric in vivado_project" \
  || die "bitstream mismatch after bootgen"

echo "   image    : blobs/BOOT.bin ($(stat -c%s blobs/BOOT.bin) bytes, md5 $(md5sum blobs/BOOT.bin | cut -c1-32))"
echo ""
echo "Built from the current tree. Commit blobs/BOOT.bin together with the source it was built from."
echo "Run the simulation suite before committing RTL:  cd programmable_logic/sim && for t in run_*.sh; do bash \$t; done"

---
name: build-image
description: Build BOOT.bin from source and prove it matches. Use for ANY change to programmable_logic/ or firmware/, and before committing or pushing a PL/firmware change. Encodes the three ways this build silently ships stale artefacts.
---

# build-image

Produces `blobs/BOOT.bin` and proves it was built from the source beside it.

**The rule this exists to enforce:** never commit or push a change under
`programmable_logic/` or `firmware/` without a `BOOT.bin` built from *that exact
source*, in *the same commit*. A source/binary mismatch is not a caveat to
mention in the commit message — it is a reason to refuse to commit. If you
cannot build, say so and stop.

## Why "just rebuild" is not enough

This build has **three independent staleness traps**. Each produces a working
image that is silently wrong — right timestamp, right size, wrong contents.
Every one of them has actually happened.

**1. Out-of-context synthesis runs.** Each block-design module synthesises as
its own run. `reset_run synth_1` resets only the top and does *not* cascade, and
Vivado's out-of-date detection misses edits to the underlying RTL. You get a
stale sub-module checkpoint stitched into a fresh top-level build. No warning.
→ `scripts/build_bitstream.tcl` resets **every** synthesis run and waits on each
child by name. Don't hand-roll a build that skips this.

**2. The Vitis platform does not follow a new `.xsa`.**
`scripts/build_vitis_project.py` has `platform.update_hw(...)` and
`platform.build()` **commented out** — it recompiles the apps only. After a PL
change it happily builds firmware against the *old* hardware definition.
→ After any PL change, delete `vitis_workspace/` and use
`scripts/create_vitis_project.py`, which regenerates the platform from the new
`.xsa`.

**3. `boot.bif` references the bitstream by an explicit path.** It packs
`vitis_workspace/klab-firmware/_ide/bitstream/klab_project.bit` — a *copy*, not
the one Vivado just produced and not the one inside the `.xsa`. A stale
workspace means `bootgen` cheerfully packs the old fabric with new firmware.
→ Verify the copy matches implementation output (gate 2 below) every time.

A fourth trap is not in the build at all: **the `vivado_project/` in your working
tree may belong to a different branch.** Its `.xsa` can be weeks old and describe
different fabric. Check before reusing it, or wipe it.

## Decide what to rebuild

| what changed | what to do |
|---|---|
| `programmable_logic/**` (RTL, block design, constraints, IP) | **Full clean build.** All five steps |
| `firmware/**` only | Steps 4–5, *provided* `vitis_workspace/` was generated from the current `.xsa`. If unsure, full clean build |
| `remote/`, `docs/`, `scripts/` (non-build) | No rebuild. `BOOT.bin` stays valid |

When in doubt, do the full clean build. It is ~15 minutes; a silently wrong
image costs far more.

## Full clean build

Run from the repo root. Wipe first — that is what makes it trustworthy.

```bash
rm -rf vivado_project vitis_workspace BOOT.bin

source /opt/Xilinx/2025.1/Vivado/settings64.sh          # `which vivado` lies before this
vivado -mode batch -nojournal -source scripts/create_vivado_project.tcl
vivado -mode batch -nojournal -source scripts/build_bitstream.tcl    # ~13-16 min; exports the .xsa

source /opt/Xilinx/2025.1/Vitis/settings64.sh
vitis -s scripts/create_vitis_project.py                # platform from the NEW .xsa + both apps
vitis -s scripts/build_vitis_project.py

bootgen -image scripts/boot.bif -arch zynq -o BOOT.bin -w
```

Long enough to run in the background; poll for `Bootimage generated successfully`.

## Verification gates

**All four must pass before you commit.** Report the actual numbers, not "looks
fine". If a gate fails, bring the failure to the user rather than committing
around it.

**Gate 1 — timing closed.**
```bash
grep -m1 -A8 "Design Timing Summary" \
  vivado_project/klab_project.runs/impl_1/design_1_wrapper_timing_summary_routed.rpt
grep -m1 "All user specified timing constraints are met" \
  vivado_project/klab_project.runs/impl_1/design_1_wrapper_timing_summary_routed.rpt
```
WNS and WHS must be positive with **0 failing endpoints**. Record WNS in the
commit message; a drop is the price of whatever you added, and worth stating.

**Gate 2 — the packed bitstream is the one you just built.** This catches trap 3
and is the single most important check.
```bash
cmp vivado_project/klab_project.runs/impl_1/design_1_wrapper.bit \
    vitis_workspace/klab-firmware/_ide/bitstream/klab_project.bit \
  && echo "OK: BOOT.bin carries the fabric just built"
```
If they differ, stage the fresh one and re-run `bootgen`:
```bash
mkdir -p vitis_workspace/klab-firmware/_ide/bitstream
cp vivado_project/klab_project.runs/impl_1/design_1_wrapper.bit \
   vitis_workspace/klab-firmware/_ide/bitstream/klab_project.bit
```

**Gate 3 — simulation clean.** Any RTL change must keep the suite green.
```bash
source /opt/Xilinx/2025.1/Vivado/settings64.sh
cd programmable_logic/sim
for tb in run_*.sh; do echo "== $tb"; bash "$tb" 2>&1 | grep -E "Checks:|TB_PASS|TB_FAIL"; done
```
Every testbench must print `TB_PASS` with `Errors: 0`. **If a testbench fails,
first re-run it with your change reverted** — establish whether the change or the
bench is at fault before touching either. A `lane_mask` latch that broke frame
publication was caught exactly this way.

**Gate 4 — provenance.** If the image was built somewhere other than the tree
you are committing (a worktree, another checkout), prove every build input is
byte-identical before copying `BOOT.bin` across:
```bash
for d in programmable_logic/src programmable_logic/constraints \
         programmable_logic/block_design programmable_logic/ip firmware scripts; do
  diff -rq "$d" "$OTHER_TREE/$d" >/dev/null && echo "  $d: identical" || echo "  $d: DIFFERS"
done
```
All must be identical. `programmable_logic/block_design/design_1_bd.tcl` and
`programmable_logic/ip/` are build inputs too and are easy to forget — the block
design carries the AXI wiring and BRAM instances, so omitting it publishes a tree
that cannot build its own image.

## Committing

Source and binary go in **one commit**. Never a commit that changes
`firmware/` or `programmable_logic/` and leaves `blobs/BOOT.bin` behind for a
later one — an intermediate checkout would then have new source against an old
image, which is the mismatch this whole skill exists to prevent.

State the verification in the commit message: WNS, failing endpoints, simulation
check count. Claims about provenance should be things you actually ran.

## Notes

- Firmware builds at **-O3**; it cannot meet timing at -O0.
- `vivado_project/` and `vitis_workspace/` are generated and gitignored. Never
  commit them; always regenerate from `scripts/`.
- A `CRITICAL WARNING` you have not seen before deserves a check against the
  previous build's log before you dismiss it — `diff` the counts. Pre-existing
  noise (DDR `PCW_UIPARAM_*` skew, `digital_in_0` direction, `set_property`)
  appears in every build; a genuinely new one usually means a width or
  connectivity mistake.

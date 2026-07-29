---
name: build-image
description: Build blobs/BOOT.bin from source. Use for ANY change to programmable_logic/ or firmware/, and before committing or pushing one.
---

# build-image

```bash
scripts/build.sh
```

That is the whole procedure. It works out for itself whether the PL needs
re-synthesising (fingerprinting the RTL, block design, constraints, IP and build
scripts), always regenerates the Vitis workspace against the current `.xsa`,
stages the bitstream `boot.bif` actually packs, runs `bootgen`, and then verifies
what it produced. A firmware-only edit takes ~3 minutes; a PL edit ~18.

It refuses to produce an image it cannot vouch for: it fails on timing not met,
on a staged bitstream that disagrees with implementation output, or on a Vitis
build that fails three times. **If it fails, bring the failure to the user — do
not work around it by hand.** Hand-running the underlying steps is how stale
artefacts get shipped, which is exactly what this script exists to prevent.

Useful variants:

```bash
scripts/build.sh --check      # say what would be rebuilt, change nothing
scripts/build.sh --force-pl   # re-synthesise the PL even if unchanged
```

Set `XILINX_ROOT` if the tools are not at `/opt/Xilinx/2025.1`.

## Before committing

**Run the simulation suite** if you touched RTL. The build does not run it,
because a design can be perfectly timed and still wrong.

```bash
cd programmable_logic/sim && for t in run_*.sh; do bash "$t"; done
```

All six must print `TB_PASS` with `Errors: 0`. If one fails, **re-run it with
your change reverted before touching either** — that distinguishes a real bug
from a bench that was already broken, and it is a 30-second check.

**Commit source and binary together.** Any commit touching `programmable_logic/`
or `firmware/` carries the `blobs/BOOT.bin` built from that exact source. Never
leave the image for a follow-up commit: an intermediate checkout would then pair
new source with an old image, which is the mismatch all of this exists to
prevent. Put the reported WNS and the simulation check count in the message.

## If the image was built somewhere else

Building in a worktree or another checkout is fine, but prove the trees agree
before copying `blobs/BOOT.bin` across:

```bash
for d in programmable_logic/src programmable_logic/constraints \
         programmable_logic/block_design programmable_logic/ip firmware scripts; do
  diff -rq "$d" "$OTHER/$d" >/dev/null && echo "  $d: identical" || echo "  $d: DIFFERS"
done
```

Every one must be identical. `block_design/` and `ip/` are build inputs as much
as the RTL — omitting them publishes a tree that cannot build its own image.

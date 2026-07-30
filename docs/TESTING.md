# Testing

RTL simulations run under Vivado's `xsim` (`source /opt/Xilinx/2025.1/Vivado/settings64.sh`
first). Host checks run from `remote/`.

## What earns a test

**A test is a liability as well as an asset.** It has to be read, kept working, and
believed. One that no longer guards anything still costs all three, and worse, a suite
full of noise trains you to skim past a real failure.

The bar for keeping a testbench here is narrow:

- **It guards a contract, not an implementation.** Byte-exact output against a
  reference, a wire format, a handshake — something that would still be true after a
  rewrite.
- **It guards code that still changes.** A test over frozen code is documentation with
  a runtime cost; write documentation instead.
- **Its failure would otherwise be silent.** The aux command path is the clearest case:
  a regression there is invisible on the wire and produces plausible-looking data.

What gets retired rather than migrated:

- one-off debug benches written to chase a specific bug, once it is fixed
- migration tests that only proved an old and a new path agreed, once the old one is gone
- anything asserting on a value that has no reason to be that value

Delete them outright. Git history keeps them if anyone ever needs to look.

## Reading a failure

**When a testbench fails after a change, re-run it with the change reverted before
touching either.** Establish whether the change or the bench is at fault — it is a
30-second control run and it is the difference between fixing a bug and inventing one.

This is not hypothetical: a `lane_mask` latch added to `lfp_dsp_block.sv` broke frame
publication in a way that looked like a flaky bench. The control run showed the bench
passing without the change, which turned a vague suspicion into a precise bug (the
first frame was being framed at zero lanes, so it emitted nothing and was never
published).

Passing simulation is necessary and not sufficient. It says the RTL does what the bench
asserts; it says nothing about whether the bench asserts the right thing, and nothing at
all about the host.

## RTL simulations (`programmable_logic/sim/`)

Each testbench has a `run_*.sh` that compiles what it needs, runs `xsim`, and prints
`RESULT: PASS` / `RESULT: FAIL` plus a check count.

```bash
cd programmable_logic/sim
source /opt/Xilinx/2025.1/Vivado/settings64.sh

bash run_dualport_dropout_tb.sh        # broadband integrity -- run this first

for tb in run_*.sh; do                 # the whole suite
  echo "== $tb"; bash "$tb" 2>&1 | grep -E "Checks:|TB_PASS|TB_FAIL"
done
```

A clean suite is **3 testbenches, 0 errors**.

| Testbench | Guards |
|---|---|
| `dualport_dropout_tb.sv` | **Broadband data integrity.** Every data word out of the wrapper is byte-exact against the RTL sine reference across both cable ports, and SEQ/timestamp advance +1 per packet with no gaps. The canonical no-loss proof |
| `data_generator_aux_wire_tb.sv` | **Aux command path on the wire.** Decodes serialised COPI out of the real core: channel CONVERTs, the programmed aux loop, one-shot injection, and the override rewrites (fast-settle, DSP-reset bit on every CONVERT, Reg-3 digout substitution). Every one of these is silent on the wire if it regresses |
| `axi_lite_write_tb.sv` | AXI-Lite register **write handshake** — catches a silently wedged control bus |

The shipped LFP **coefficients (`*_coefs.hex`) are tracked** — they are the filter that ships
in the bitstream — and `design_lfp_filters.py` regenerates them along with `lfp_coef_pkg.sv`.

## check-dma guardrail (`.claude/skills/check-dma/`)

Scans for the anti-pattern where a PL→PS bulk-data path loops the CPU over BRAM or the
DMA staging buffer instead of using CDMA. Run before declaring a data-path change done.
Genuinely justified single-beat reads (a 2-word magic/resync peek, say) must be annotated
`// DMA-EXEMPT: <reason>`.

## Host-side (`remote/net.py`)

```bash
python3 net.py           # TCP 0x6900 control, unified UDP 0x6800 data
```

Connects, starts streaming, and validates the stream: per-stream SEQ continuity (the
loss check), magic and size checks, cable/phase detection. **A clean run shows 0 SEQ
gaps** — loss is proven, not assumed.

`sink` prints live per-stream counters: packet counts, per-stream SEQ gaps, and the last
sender. Run it twice a few seconds apart — what matters is whether a gap count is still
climbing, not its absolute value.

## Before believing any packet-loss report

```bash
python3 netperf_loopback.py 30 20 154 0     # broadband only
python3 netperf_loopback.py 30 20 154 10    # + the LFP mix
```

Pure `127.0.0.1`, no board, 20 seconds. Healthy is ~30,000 pkt/s drained with 0 SEQ
gaps. **Run this before touching firmware, PL, or `net.py`.** A degraded host has
repeatedly presented as a board-side bug, and this separates the two in less time than
it takes to form a theory.

Note what a loopback shortfall does and does not prove. It shows the problem is on the
host — not the board, not the PL. It rules out app-layer network filtering, which cannot
touch loopback. It does **not** rule out a system network extension (a VPN content filter
or transparent proxy), which sits lower and can degrade loopback along with everything
else.

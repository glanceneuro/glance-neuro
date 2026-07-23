# Testing

The verification that ships with the broadband + aux datapath. RTL sims use Vivado's
`xsim` (`source /opt/Xilinx/2025.1/Vivado/settings64.sh` first); each `run_*.sh`
compiles the RTL it needs, runs the sim, and prints `RESULT: PASS` / `RESULT: FAIL`.

Every test here asserts *intended behavior directly* — against a spec-derived
reference or the AXI protocol, never a diff against older code — so it stays
meaningful as the design evolves. Run the relevant one after changing the code it
covers; each testbench's header says what it guards and when it should legitimately
fail.

## RTL simulations (`programmable_logic/sim/`)

| Testbench | Guards | Re-run when you touch |
|---|---|---|
| `dualport_dropout_tb` | The **no-data-loss** contract: the full datapath at the 0xFF worst case — no stuck/frozen channels, the 14-word unified header well-formed, every sample byte-exact vs the sine reference, and SEQ / timestamp / index advancing +1 per packet (the SEQ check *is* the loss check). | the acquisition core, the FIFO→BRAM packer, the packet/header format, or channel packing |
| `data_generator_aux_wire_tb` | The **aux command path on the wire**: decodes the serialized COPI out of the real core and checks the always-on aux commands reach the chip — the channel `CONVERT`s, the slot-0 program loop, the one-shot slot-2 inject, and the override rewrites (fast-settle `WRITE(0)`+D5, DSP-reset bit-H on every `CONVERT`, Reg-3 digout D0). Any of these is silent on the wire if it regresses. | the aux engine, `aux_program`, the override rewrites, or the frame geometry (`acq_frame_pkg`) |
| `axi_lite_write_tb` | The **AXI-Lite write handshake**: a write must complete for every legal AW/W arrival order, else the PS hangs mid-store — a silent bus wedge that stops the board accepting commands. | `axi_lite_registers.v` — i.e. any time the register map grows |

```bash
cd programmable_logic/sim
source /opt/Xilinx/2025.1/Vivado/settings64.sh
bash run_dualport_dropout_tb.sh    # the no-loss proof
bash run_aux_wire_tb.sh            # the aux command path on the wire
bash run_axi_write_tb.sh
```

## check-dma guardrail (`scripts/check_dma.sh`, `.claude/skills/check-dma/`)

A static check for the one anti-pattern that silently breaks the data path: moving
PL→PS bulk data by looping the CPU over BRAM/staging instead of AXI-CDMA (slow, and
CPU bursts corrupt the 0xFF stream). Run it before declaring any PL↔PS data-path
change done; annotate genuinely-justified single-beat peeks `// DMA-EXEMPT: <reason>`.

## Host-side validation (`remote/net.py`)

`python3 remote/net.py` connects (TCP `0x6900`), streams, and validates the UDP data
(`0x6800`): per-stream SEQ continuity (the loss check), magic/size checks, and
cable/phase detection. A clean run shows **0 SEQ gaps**.

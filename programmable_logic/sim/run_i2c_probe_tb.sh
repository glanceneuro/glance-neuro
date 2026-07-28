#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
# I2C presence probe vs a behavioral BNO055 slave (present / wrong-id / absent /
# not-both-high / clock-stretch).
# Usage: source /opt/Xilinx/2025.1/Vivado/settings64.sh && bash run_i2c_probe_tb.sh
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src"
WORK="$(mktemp -d)"; cd "$WORK" || exit 99
xvlog -sv "$SRC/i2c_probe.sv" "$HERE/i2c_probe_tb.sv" || exit 1
xelab -debug off -timescale 1ns/1ps work.i2c_probe_tb -s tb_snap || exit 1
xsim tb_snap -R | tee sim.log
grep -q "RESULT: PASS" sim.log && { echo "TB_PASS"; exit 0; } || { echo "TB_FAIL"; exit 1; }

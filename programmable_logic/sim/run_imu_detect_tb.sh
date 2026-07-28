#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
# imu_detect_top AXI-Lite integration: two probes, port A=IMU / port B=none.
# Uses the Xilinx IOBUF primitive, so elaborate with the unisims library.
# Usage: source /opt/Xilinx/2025.1/Vivado/settings64.sh && bash run_imu_detect_tb.sh
set -o pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../src"
WORK="$(mktemp -d)"; cd "$WORK" || exit 99
xvlog -sv "$SRC/i2c_probe.sv" "$SRC/imu_detect_top.v" \
      "$HERE/i2c_slave_model.sv" "$HERE/imu_detect_tb.sv" || exit 1
xvlog "$XILINX_VIVADO/data/verilog/src/glbl.v" || exit 1
xelab -debug off -timescale 1ns/1ps -L unisims_ver -L secureip \
      work.imu_detect_tb work.glbl -s tb_snap || exit 1
xsim tb_snap -R | tee sim.log
grep -q "RESULT: PASS" sim.log && { echo "TB_PASS"; exit 0; } || { echo "TB_FAIL"; exit 1; }

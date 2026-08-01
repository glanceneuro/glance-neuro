#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
#
# Build and run the bounded-I2C tests: pl_imu_read.c, pl_i2c_probe.c and
# pl_imu_detect.c against the simulated IIC core. No board, no Xilinx tools.
#
# `timeout` is load-bearing, not belt-and-braces: the bug these files exist to
# guard against is an UNBOUNDED wait, and a revert of that fix hangs rather
# than fails. The timeout converts that hang into a test failure.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
BUILD=../../vitis_workspace/.host-test
mkdir -p "$BUILD" 2>/dev/null || BUILD=$(mktemp -d)
cc -O1 -g -Wall -Wextra -Werror -DIMU_PROBE_TEST \
   -I. -I../include \
   ../src-core0/pl_imu_read.c ../src-core0/pl_i2c_probe.c \
   ../src-core0/pl_imu_detect.c imu_host_mock.c test_probe.c \
   -o "$BUILD/test_probe"
timeout 30 "$BUILD/test_probe" || {
    rc=$?
    [ $rc -eq 124 ] && echo "TB_FAIL  timed out -- an I2C wait is UNBOUNDED"
    exit $rc
}

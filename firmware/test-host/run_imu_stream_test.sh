#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
#
# Build and run the host-side IMU stream state-machine tests. No board and no
# Xilinx tools needed -- any host gcc. Exits non-zero on failure; the pass
# line matches the RTL benches' convention (TB_PASS / Errors: 0).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
BUILD=../../vitis_workspace/.host-test
mkdir -p "$BUILD" 2>/dev/null || BUILD=$(mktemp -d)
cc -O1 -g -Wall -Wextra -Werror -DIMU_HOST_TEST \
   -I. -I../include \
   ../src-core0/pl_imu_stream.c imu_host_mock.c test_imu_stream.c \
   -o "$BUILD/test_imu_stream"
"$BUILD/test_imu_stream"

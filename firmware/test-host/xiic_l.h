// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Host-test stand-in for the BSP's xiic_l.h. The simulated core already lives
// in imu_host_mock.h; this just lets firmware sources that include the vendor
// header compile unchanged against it.
#ifndef XIIC_L_H
#define XIIC_L_H
#include "imu_host_mock.h"
#define XIIC_SR_TX_FIFO_EMPTY_MASK  0x00000080
#endif

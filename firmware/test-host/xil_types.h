// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Host-test stand-in for the BSP's xil_types.h, so firmware headers that only
// need the basic typedefs (pl_imu_read.h) can be included by the host-side
// IMU stream tests unchanged.
#ifndef XIL_TYPES_H
#define XIL_TYPES_H

#include <stdint.h>

typedef uintptr_t UINTPTR;
typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;

#endif

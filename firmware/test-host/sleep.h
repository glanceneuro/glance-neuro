// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Host-test usleep. Advancing the MOCK clock is the point: the firmware's own
// bounded poll loops call usleep between polls, so this is what lets their
// deadlines actually expire in simulated time instead of wall time.
#ifndef SLEEP_H
#define SLEEP_H
#include "imu_host_mock.h"
static inline void usleep(unsigned us) { mock_advance_us(us); }
#endif

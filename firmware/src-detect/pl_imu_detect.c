// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University

#include "pl_imu_detect.h"
#include "xil_io.h"
#include "sleep.h"

static inline void imudet_wr(uint32_t off, uint32_t v) { Xil_Out32(IMUDET_BASE_ADDR + off, v); }
static inline uint32_t imudet_rd(uint32_t off)         { return Xil_In32(IMUDET_BASE_ADDR + off); }

int pl_imu_detect_run(imu_detect_response_t *out)
{
    imudet_wr(IMUDET_REG_CONTROL, 1u);   // start both ports

    // Both probes are slow I2C; a full probe is well under a millisecond even
    // with clock stretching, but poll with a generous ceiling. Cold path.
    for (int i = 0; i < 100000; i++) {
        if (imudet_rd(IMUDET_REG_STATUS) & IMUDET_STATUS_DONE) {
            out->result_a = imudet_rd(IMUDET_REG_RESULT_A);
            out->result_b = imudet_rd(IMUDET_REG_RESULT_B);
            out->version  = imudet_rd(IMUDET_REG_VERSION);
            return 0;
        }
        usleep(10);
    }
    out->result_a = 0; out->result_b = 0;
    out->version  = imudet_rd(IMUDET_REG_VERSION);
    return -1;   // PL never reported done
}

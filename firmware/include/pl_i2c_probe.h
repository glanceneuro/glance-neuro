// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
//
// Generic probes for a headstage port's I2C bus (the freed-CIPO pair the
// BNO055 lives on): a full-bus address scan and a bounded EEPROM/register
// read. Cold paths for identification and inventory -- the continuous IMU
// stream owns the fast path.
//
// Everything here polls with a DEADLINE, never an open wait: an AXI IIC
// transaction on a wedged bus (e.g. the pair is actually an LVDS output on a
// mis-classified cable) must degrade to an error code, not hang core 0 the
// way the absent-slave AXI read once did.
#ifndef PL_I2C_PROBE_H
#define PL_I2C_PROBE_H

#include <stdint.h>
#include "xil_types.h"

#define I2C_SCAN_FIRST     0x08     // below 0x08 / above 0x77 are reserved addresses
#define I2C_SCAN_LAST      0x77
#define I2C_SCAN_VERSION   0x49324353   // "I2CS"
#define EEPROM_READ_VERSION 0x45455244  // "EERD"
#define EEPROM_READ_MAX    32

// CMD_I2C_SCAN reply: which 7-bit addresses ACKed, one bit per address
// (bit n of byte n/8 = address n). status: 0 = ok; 1 = bus wedged, scan
// aborted (the offending address in [15:8] -- its bit and all later ones are
// unprobed). A 24xx EEPROM <=16 Kbit block-addresses ALL of 0x50-0x57, so
// eight ACKs there may be ONE chip (docs/headstage-eeprom.md).
typedef struct __attribute__((packed)) {
    uint32_t status;
    uint8_t  bitmap[16];
    uint32_t version;       // I2C_SCAN_VERSION
} i2c_scan_response_t;
_Static_assert(sizeof(i2c_scan_response_t) == 24,
               "i2c scan response must stay 24 bytes (net.py decode)");

// CMD_EEPROM_READ reply. status: 0 ok; 1 = no ACK at the device address;
// 2 = timed out (wedged); 3 = short read (len in [15:8] got, requested in
// [23:16]).
typedef struct __attribute__((packed)) {
    uint32_t status;
    uint32_t nbytes;
    uint8_t  data[EEPROM_READ_MAX];
    uint32_t version;       // EEPROM_READ_VERSION
} eeprom_read_response_t;
_Static_assert(sizeof(eeprom_read_response_t) == 44,
               "eeprom read response must stay 44 bytes (net.py decode)");

// Scan one port's bus (port 0 = A, 1 = B). Caller must have checked the
// fabric carries that port's IIC. ~200 us per address, so a clean scan of
// 0x08..0x77 is ~25 ms; a wedged bus costs one 5 ms deadline then aborts.
void pl_i2c_scan(int port, i2c_scan_response_t *out);

// Read up to EEPROM_READ_MAX bytes from a device on the port's bus.
// addr_width: 1 = single offset byte (24xx <=16 Kbit, BNO055 registers...),
// 2 = big-endian 2-byte offset (24xx >=32 Kbit). Non-destructive: the offset
// write only sets the device's read pointer.
void pl_i2c_read(int port, uint8_t i2c_addr, int addr_width, uint16_t offset,
                 uint8_t nbytes, eeprom_read_response_t *out);

#endif // PL_I2C_PROBE_H

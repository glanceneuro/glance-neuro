# Headstage EEPROM — identity record

**Status: READ AND DECODED on hardware** (port A, 2026-07-31). The part is not
blank and the record format is not ours: the headstage ships an
Open-Ephys-authored identity record that names the board. Probe tooling is
`CMD_I2C_SCAN 0xB7` / `CMD_EEPROM_READ 0xB9`, `net.py i2c_scan` / `eeprom_read`
— see `docs/protocol.md`.

> **Do not write to this device.** It carries vendor identity data that nothing
> in this repo can regenerate. `CMD_EEPROM_READ` is read-only by construction
> (the offset write only moves the read pointer) and there is deliberately no
> write command. An earlier draft of this document proposed defining *our own*
> identity record here; that would have destroyed the manufacturer's.

## The bus (validated)

- Each cable carries an I2C bus on the freed 2nd-CIPO pair (SCL on the -P pin,
  SDA on the -N pin; 2 kOhm pull-ups on the headstage; 100 kHz; LVCMOS25 —
  `constraints/variants/acq_imu_*_pins.xdc`: M20=SDA/M19=SCL on port A,
  J16=SDA/K16=SCL on port B).
- A BNO055 sits on that bus at **0x28** (chip_id 0xA0, hardware, 2026-07-30).
- The EEPROM answers at **0x50** with **1-byte word addressing**: two reads at
  offsets 0 and 32 returned a record that is contiguous across the boundary
  (the name string continues mid-word), which is what confirms the addressing
  width — a 2-byte part fed one address byte would have returned garbage on the
  second read.
- The probe path that works: `XIic_DynInit`, then the combined write-then-read
  the rest of the firmware uses, driven by the BOUNDED `pl_imu_bno_read`
  (`firmware/src-core0/pl_imu_read.c`). The vendor's `XIic_DynSend`/`XIic_DynRecv`
  are deliberately NOT used anywhere reachable from a command handler: they spin
  on `BUS_BUSY` with no timeout.

## The record, as read

```
0000: 4f 45 53 48 02 00 38 00 02 00 00 80 01 00 26 00  OESH..8.......&.
0010: 53 50 49 20 48 65 61 64 73 74 61 67 65 20 33 32  SPI Headstage 32
0020: 63 68 20 77 69 74 68 20 33 44 20 28 4f 6d 6e 65  ch with 3D (Omne
0030: 74 69 63 73 29 00 00 e6 ff ff ff ff ff ff ff ff  tics)...........
```

### Layout

| offset | width | value | what |
|---|---|---|---|
| 0x00 | 4 | `"OESH"` | magic — **verified** |
| 0x04 | u16 LE | 2 | format version (inferred) |
| 0x06 | u16 LE | 56 | **record length — verified**: the first `0xFF` byte is at exactly offset 56 |
| 0x08 | u16 LE | 2 | unknown; plausibly a device-class code |
| 0x0A | u16 LE | 0x8000 | unknown; single high bit set, reads like a flags word |
| 0x0C | u16 LE | 1 | unknown; plausibly a hardware revision |
| 0x0E | u16 LE | 38 | **name length incl. NUL — verified**: the string is 37 chars + terminator |
| 0x10 | 38 | `"SPI Headstage 32ch with 3D (Omnetics)\0"` | **board name — verified** |
| 0x36 | 1 | 0x00 | pad, or the high byte of a 16-bit checksum |
| 0x37 | 1 | 0xE6 | **checksum — verified**: the 56 record bytes sum to 0 mod 256 |
| 0x38.. | — | 0xFF | erased; never written |

Three independent structural facts agree — the declared length, the first erased
byte, and a checksum that only validates over exactly those 56 bytes. **The
record is complete at 56 bytes; there is nothing further to read.** The four
unknown header fields are constants on this unit, so distinguishing "device
class" from "revision" needs a second headstage of a different type to compare
against, not more bytes from this one.

### What it tells us

The name string carries two things this firmware currently works out the hard
way, by probing:

- **`32ch`** — the channel count. Also readable live from the RHD ROM
  (regs 40–44, 62, 63), so this is corroboration rather than new information.
- **`3D`** — the presence of the 3-axis motion sensor, i.e. the BNO055 that
  `rescan` currently discovers with an I2C census.

`OESH` and the naming style are Open Ephys's, matching their published headstage
range. Treat the format as third-party: parse it, do not extend it.

## The probe tooling (implemented)

1. **`CMD_I2C_SCAN 0xB7`** (`firmware/src-core0/pl_i2c_probe.c`): for each 7-bit
   address 0x08–0x77, an **address-only** probe (START, addr, STOP — no data
   byte, so it cannot trigger a command on a device it is merely looking for),
   with ACK/NACK recorded in a 16-byte bitmap. Per-port IIC-gated (the
   mixed-fabric hang lesson), and every wait is **deadline-bounded**: a wedged
   bus aborts the scan with a status code instead of hanging core 0.
   `net.py i2c_scan [a|b]` prints an i2cdetect-style map and auto-flags the
   ≤16 Kbit block-addressing signature (all of 0x50–0x57 ACKing = one chip).
2. **`CMD_EEPROM_READ 0xB9`**: bounded combined write-then-read of ≤32 bytes
   from any device/offset, 1- or 2-byte offset addressing selected by the host.
   `net.py eeprom_read [a|b] [dev] [off] [len] [width]` hex-dumps the result.

### Addressing subtlety worth keeping

- **≤16 Kbit parts (24LC01–24LC16) use 1-byte word addressing**, and a 24LC16
  uses A2..A0 as *block-select* — one chip **ACKs all eight addresses
  0x50–0x57**. So "all 8 addresses ACK" ≠ "8 devices". **This part answers only
  at 0x50** (scanned on hardware), so it is not a 24LC16: a smaller 24xx with
  A2..A0 strapped or ignored. Exact size is unknown and unimportant — nothing
  reads past offset 63, and the record ends at 56.
- **≥32 Kbit parts use 2-byte word addressing** and occupy one address.
- 0x28/0x29 (BNO055 primary/alternate) and 0x50–0x57 don't collide.

## Possible follow-up

`rescan` could read the name string instead of inferring the headstage type from
the IMU census — it is one bounded 32-byte read per port and it states the
board's identity directly rather than deducing it. Worth doing only if a
headstage turns up whose census is ambiguous; today the census and the string
agree, so the probe is not wrong, just indirect.

## Still open

- Is WP tied high? Unresolved and **not worth resolving by experiment** — the
  only test is a write, and the thing we would be writing over is the identity
  record.
- The meaning of the four unknown header fields (0x04, 0x08, 0x0A, 0x0C), which
  needs a differently-configured headstage to compare against.

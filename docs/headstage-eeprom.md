# Headstage EEPROM — investigation & probe proposal

**Status: DRAFT (overnight 2026-07-30), investigation only — no firmware change.**
The headstage schematic is not in this repo or glance-neuro-hardware (the carrier
KiCad files have no EEPROM/BNO055; those parts are on the headstage itself), so
everything below is inferred from the bus facts we have validated plus 24xx-family
convention. Caleb has the schematic — see the open questions.

## What we know (validated)

- Each cable carries an I2C bus on the freed 2nd-CIPO pair (SCL on the -P pin,
  SDA on the -N pin; 2 kOhm pull-ups on the headstage; 100 kHz; LVCMOS25 —
  `docs/imu-detect.md`, `detect_pins.xdc`).
- A BNO055 sits on that bus at **0x28** (chip_id 0xA0 read on hardware,
  2026-07-30, port A).
- The probe path that works: `XIic_DynInit` → `XIic_DynSend`(addr, reg-pointer,
  repeated start) → `XIic_DynRecv` (`firmware/src-core0/pl_imu_detect.c`).

## What the EEPROM most likely is

A 24xx-series serial EEPROM (24AA/24LC/M24Cxx/AT24Cxx — all wire-compatible),
device type code `1010` → base address **0x50**, with A2..A0 straps selecting
0x50–0x57. This is far and away the standard choice for board-identity storage
on an I2C bus that already exists for another device (the BNO055).

Likely contents (to be defined by us if the part is blank): headstage identity —
serial number, headstage type / channel count (64 vs 128), hardware revision —
and possibly IMU mounting orientation. Chip-level facts (chip ID, #amps) are
already readable live from the RHD ROM (regs 40–44, 62, 63), so the EEPROM's
value is what the silicon can't tell us: which *board* this is and how it is
assembled.

### Addressing subtlety worth knowing before probing

- **≤16 Kbit parts (24LC01–24LC16) use 1-byte word addressing**, and a 24LC16
  uses the A2..A0 bits as *block-select* — one 16 Kbit chip **ACKs all eight
  addresses 0x50–0x57**. So "all 8 addresses ACK" ≠ "8 devices".
- **≥32 Kbit parts (24LC32 and up) use 2-byte word addressing** and occupy just
  one address. Sending only one address byte to these still ACKs but points the
  read somewhere undefined — so a probe should only trust the *address ACK*, not
  the data byte, until the part is identified.
- 0x28/0x29 (BNO055 primary/alternate) and 0x50–0x57 don't collide, so a scan
  can't confuse the two.

## Proposed probe (when we next touch firmware — not committed yet)

Extend the detect path with a generic per-port **bus scan** rather than an
EEPROM-specific read:

1. `CMD_I2C_SCAN` (new, e.g. 0xB6): for each 7-bit address in 0x08–0x77, one
   `XIic_DynSend(base, addr, &zero, 1, stop)` and record ACK/no-ACK. Reply = a
   16-byte bitmap per port. This finds the BNO055 (sanity check), the EEPROM,
   and anything else on the bus in one shot, and needs no assumption about the
   part. Runs on any fabric with that port's IIC, gated per-port like
   detect_imu (`pl_has_iic_a/_b` — the mixed-fabric hang lesson).
2. Once the address is known, a `CMD_EEPROM_READ` with {addr, offset, len ≤ 32}
   using the word-addressing width established from the schematic (or from the
   block-ACK signature above).
3. `net.py`: `i2c_scan` command printing per-port maps; later `eeprom_read`.
   `rescan` could then also read identity bytes instead of inferring headstage
   type purely from the IMU census.

A scan writes nothing (a single address byte to a 24xx only sets its read
pointer), so it is non-destructive even against a live EEPROM.

## Assumptions

1. The EEPROM shares the freed-CIPO1 bus with the BNO055 (it would need its own
   pins otherwise, and none are free on the 12-pin Omnetics).
2. It is a 24xx-type part at 0x50–0x57; nothing else on the bus.
3. Probing extra addresses is electrically safe on IMU headstages; on a plain
   128-ch headstage the same caveat as rescan assumption 2 applies (driving I2C
   into an LVDS-driven pair — assumed harmless, unconfirmed).

## Open questions (Caleb — schematic)

- Exact part number and strapped address? (Also answers 1-byte vs 2-byte word
  addressing.)
- Is WP (write-protect) tied high? If writable in-system, we can program
  identity records from `net.py`; if strapped protected, contents must be
  programmed at assembly.
- Is the part blank today, or did the headstage design already define contents?
- Should we define an identity record format (magic + version + serial + type +
  channel count + IMU orientation), and who owns allocation of serials?

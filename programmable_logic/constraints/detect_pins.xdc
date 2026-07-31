# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# Pin constraints for the IMU-DETECT bitstream ONLY (two AXI IIC controllers).
# These four pins are the 2nd-CIPO (MISO) LVDS pairs of the two headstage ports
# in the acquisition image (intan_io.xdc: M19/M20 port A, K16/J16 port B). Here
# they are single-ended LVCMOS25 open-drain I2C to the headstage IMU. Bank 35
# VCCO is 2.5 V (BNO055 I2C domain); the 2 kOhm pull-ups are on the headstage.
# Do NOT combine with intan_io.xdc -- the images configure these pins
# differently and are built separately.
#
# SDA/SCL-to-pin mapping is CONFIRMED on hardware: a BNO055 headstage on port A
# ACKed at 0x28 and returned chip_id 0xA0 with SDA on the -N pin and SCL on the
# -P pin of each pair (i.e. the opposite of the first guess). Do not "fix" this
# back -- the reversed order below is the working GLANCE cable convention.

# ---- Port A: 2nd-CIPO pair M19/M20 ----
set_property PACKAGE_PIN M20 [get_ports iic_a_sda_io]
set_property PACKAGE_PIN M19 [get_ports iic_a_scl_io]

# ---- Port B: 2nd-CIPO pair K16/J16 ----
set_property PACKAGE_PIN J16 [get_ports iic_b_sda_io]
set_property PACKAGE_PIN K16 [get_ports iic_b_scl_io]

set_property IOSTANDARD LVCMOS25 [get_ports {iic_a_sda_io iic_a_scl_io iic_b_sda_io iic_b_scl_io}]
set_property SLEW SLOW           [get_ports {iic_a_sda_io iic_a_scl_io iic_b_sda_io iic_b_scl_io}]
set_property DRIVE 8             [get_ports {iic_a_sda_io iic_a_scl_io iic_b_sda_io iic_b_scl_io}]

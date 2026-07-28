# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# Pin constraints for the IMU-DETECT bitstream ONLY. These four pins are the
# 2nd-CIPO (MISO) LVDS pairs of the two headstage ports in the acquisition
# image (intan_io.xdc: M19/M20 port A, K16/J16 port B). Here they are single-
# ended LVCMOS25 open-drain carrying the shared-lane I2C to the headstage IMU.
# Bank 35 VCCO is 2.5 V, matching the BNO055 I2C domain; the 2 kOhm pull-ups
# live on the headstage. Do NOT combine this file with intan_io.xdc — the two
# images configure these pins differently and are built separately.
#
# SDA/SCL-vs-pin assignment below follows the GLANCE shared-cable convention;
# if the final cable swaps them, swap the two PACKAGE_PIN lines per port.

# ---- Port A: 2nd-CIPO pair M19/M20 -> SDA/SCL ----
set_property PACKAGE_PIN M19 [get_ports sda_a]
set_property PACKAGE_PIN M20 [get_ports scl_a]

# ---- Port B: 2nd-CIPO pair K16/J16 -> SDA/SCL ----
set_property PACKAGE_PIN K16 [get_ports sda_b]
set_property PACKAGE_PIN J16 [get_ports scl_b]

set_property IOSTANDARD LVCMOS25 [get_ports {sda_a scl_a sda_b scl_b}]
set_property SLEW SLOW           [get_ports {sda_a scl_a sda_b scl_b}]
set_property DRIVE 8             [get_ports {sda_a scl_a sda_b scl_b}]
# Open-drain behaviour comes from the IOBUF tristate in imu_detect_top (drive
# low or Hi-Z); the line is pulled up externally on the headstage.

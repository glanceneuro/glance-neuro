# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# SDA/SCL-SWAPPED variant of detect_pins.xdc. Identical in every way except the
# two signals are assigned to the opposite physical pins of each 2nd-CIPO pair.
# Use this to resolve the cable convention when detect_pins.xdc gives no ACK in
# any state but the AXI IIC status register reads alive (~0xC0): the controller
# works, so the SDA/SCL guess was backwards. Built as BOOT-detect-swap.bin.

# ---- Port A: 2nd-CIPO pair M19/M20 (swapped vs detect_pins.xdc) ----
set_property PACKAGE_PIN M20 [get_ports iic_a_sda_io]
set_property PACKAGE_PIN M19 [get_ports iic_a_scl_io]

# ---- Port B: 2nd-CIPO pair K16/J16 (swapped vs detect_pins.xdc) ----
set_property PACKAGE_PIN J16 [get_ports iic_b_sda_io]
set_property PACKAGE_PIN K16 [get_ports iic_b_scl_io]

set_property IOSTANDARD LVCMOS25 [get_ports {iic_a_sda_io iic_a_scl_io iic_b_sda_io iic_b_scl_io}]
set_property SLEW SLOW           [get_ports {iic_a_sda_io iic_a_scl_io iic_b_sda_io iic_b_scl_io}]
set_property DRIVE 8             [get_ports {iic_a_sda_io iic_a_scl_io iic_b_sda_io iic_b_scl_io}]

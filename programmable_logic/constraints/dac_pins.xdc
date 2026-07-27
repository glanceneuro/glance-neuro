# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# DAC70502 SPI pins (stimulus output), bank 34 / VCCIO34 = 3.3 V.
# Pin and electrical settings are the ones bench-verified on this carrier by
# the spi_dac_70502 reference project (JX1 pins 74/70/68). The reference's
# TTL debug mirror pins (W16/V16/W20) are deliberately NOT used here: they
# are digital_in_0[2:0] on GLANCE.
set_property PACKAGE_PIN W18 [get_ports dac_sclk]
set_property PACKAGE_PIN R18 [get_ports dac_sync_n]
set_property PACKAGE_PIN T17 [get_ports dac_sdin]
set_property IOSTANDARD LVCMOS33 [get_ports {dac_sclk dac_sync_n dac_sdin}]
set_property SLEW SLOW [get_ports {dac_sclk dac_sync_n dac_sdin}]
set_property DRIVE 8 [get_ports {dac_sclk dac_sync_n dac_sdin}]

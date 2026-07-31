# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
#
# Pin constraints for the acq_imu_both fabric: both cables run 64-ch (CIPO0 only)
# over LVDS, and the freed second-CIPO pins carry a single-ended I2C bus each for
# a BNO055 IMU. Derived from intan_io.xdc (the LVDS lanes, minus CIPO1) and
# detect_pins.xdc (the I2C lanes). Added explicitly by acq_imu_both_build.tcl --
# it must NOT sit in the globbed constraints/ dir, since the plain acquisition
# build would then double-assign spi_lvds_*_sclk_p etc.
#
# The second-CIPO pins are LVCMOS25 I2C here and LVDS_25 (CIPO1) in the plain acq
# image -- the same physical balls, reconfigured per bitstream (7-series IOBs
# cannot switch I/O standard via partial reconfiguration, hence separate fabrics).

set CLK [get_clocks clk_out1_design_1_clk_wiz_0_84M_175M_0]

#==============================================================================
# PORT A (cable A) -- spi_lvds_0, LVDS_25, 64-ch (CIPO0 only)
#==============================================================================
# SCLK (output)
set_property IOSTANDARD LVDS_25 [get_ports {spi_lvds_0_sclk_p spi_lvds_0_sclk_n}]
set_property PACKAGE_PIN E17 [get_ports spi_lvds_0_sclk_p]
set_property PACKAGE_PIN D18 [get_ports spi_lvds_0_sclk_n]
set_output_delay -clock $CLK -max  2.0 [get_ports {spi_lvds_0_sclk_p spi_lvds_0_sclk_n}]
set_output_delay -clock $CLK -min -2.0 [get_ports {spi_lvds_0_sclk_p spi_lvds_0_sclk_n}]
# CSN (output, active low)
set_property IOSTANDARD LVDS_25 [get_ports {spi_lvds_0_csn_p spi_lvds_0_csn_n}]
set_property PACKAGE_PIN D19 [get_ports spi_lvds_0_csn_p]
set_property PACKAGE_PIN D20 [get_ports spi_lvds_0_csn_n]
set_output_delay -clock $CLK -max  2.0 [get_ports {spi_lvds_0_csn_p spi_lvds_0_csn_n}]
set_output_delay -clock $CLK -min -2.0 [get_ports {spi_lvds_0_csn_p spi_lvds_0_csn_n}]
# COPI (output)
set_property IOSTANDARD LVDS_25 [get_ports {spi_lvds_0_copi_p spi_lvds_0_copi_n}]
set_property PACKAGE_PIN F16 [get_ports spi_lvds_0_copi_p]
set_property PACKAGE_PIN F17 [get_ports spi_lvds_0_copi_n]
set_output_delay -clock $CLK -max  2.0 [get_ports {spi_lvds_0_copi_p spi_lvds_0_copi_n}]
set_output_delay -clock $CLK -min -2.0 [get_ports {spi_lvds_0_copi_p spi_lvds_0_copi_n}]
# CIPO0 (input)
set_property IOSTANDARD LVDS_25 [get_ports {spi_lvds_0_cipo0_p spi_lvds_0_cipo0_n}]
set_property PACKAGE_PIN E18 [get_ports spi_lvds_0_cipo0_p]
set_property PACKAGE_PIN E19 [get_ports spi_lvds_0_cipo0_n]
set_property DIFF_TERM TRUE  [get_ports spi_lvds_0_cipo0_p]
set_input_delay -clock $CLK -max 3.0 [get_ports {spi_lvds_0_cipo0_p spi_lvds_0_cipo0_n}]
set_input_delay -clock $CLK -min 0.5 [get_ports {spi_lvds_0_cipo0_p spi_lvds_0_cipo0_n}]
# Slew / drive on the port-A outputs
set_property SLEW FAST [get_ports {spi_lvds_0_sclk_p spi_lvds_0_csn_p spi_lvds_0_copi_p}]
set_property DRIVE 12  [get_ports {spi_lvds_0_sclk_p spi_lvds_0_csn_p spi_lvds_0_copi_p}]

#==============================================================================
# PORT B (cable B) -- spi_lvds_1, LVDS_25, 64-ch (CIPO0 only). Bank-35 pairs.
#==============================================================================
# SCLK (output, IO_L17)
set_property IOSTANDARD LVDS_25 [get_ports {spi_lvds_1_sclk_p spi_lvds_1_sclk_n}]
set_property PACKAGE_PIN J20 [get_ports spi_lvds_1_sclk_p]
set_property PACKAGE_PIN H20 [get_ports spi_lvds_1_sclk_n]
set_output_delay -clock $CLK -max  2.0 [get_ports {spi_lvds_1_sclk_p spi_lvds_1_sclk_n}]
set_output_delay -clock $CLK -min -2.0 [get_ports {spi_lvds_1_sclk_p spi_lvds_1_sclk_n}]
# CSN (output, IO_L15)
set_property IOSTANDARD LVDS_25 [get_ports {spi_lvds_1_csn_p spi_lvds_1_csn_n}]
set_property PACKAGE_PIN F19 [get_ports spi_lvds_1_csn_p]
set_property PACKAGE_PIN F20 [get_ports spi_lvds_1_csn_n]
set_output_delay -clock $CLK -max  2.0 [get_ports {spi_lvds_1_csn_p spi_lvds_1_csn_n}]
set_output_delay -clock $CLK -min -2.0 [get_ports {spi_lvds_1_csn_p spi_lvds_1_csn_n}]
# COPI (output, IO_L19)
set_property IOSTANDARD LVDS_25 [get_ports {spi_lvds_1_copi_p spi_lvds_1_copi_n}]
set_property PACKAGE_PIN H15 [get_ports spi_lvds_1_copi_p]
set_property PACKAGE_PIN G15 [get_ports spi_lvds_1_copi_n]
set_output_delay -clock $CLK -max  2.0 [get_ports {spi_lvds_1_copi_p spi_lvds_1_copi_n}]
set_output_delay -clock $CLK -min -2.0 [get_ports {spi_lvds_1_copi_p spi_lvds_1_copi_n}]
# CIPO0 = cipo2 (input, IO_L22)
set_property IOSTANDARD LVDS_25 [get_ports {spi_lvds_1_cipo0_p spi_lvds_1_cipo0_n}]
set_property PACKAGE_PIN L14 [get_ports spi_lvds_1_cipo0_p]
set_property PACKAGE_PIN L15 [get_ports spi_lvds_1_cipo0_n]
set_property DIFF_TERM TRUE  [get_ports spi_lvds_1_cipo0_p]
set_input_delay -clock $CLK -max 3.0 [get_ports {spi_lvds_1_cipo0_p spi_lvds_1_cipo0_n}]
set_input_delay -clock $CLK -min 0.5 [get_ports {spi_lvds_1_cipo0_p spi_lvds_1_cipo0_n}]
# Slew / drive on the port-B outputs
set_property SLEW FAST [get_ports {spi_lvds_1_sclk_p spi_lvds_1_csn_p spi_lvds_1_copi_p}]
set_property DRIVE 12  [get_ports {spi_lvds_1_sclk_p spi_lvds_1_csn_p spi_lvds_1_copi_p}]

#==============================================================================
# I2C -- the freed second-CIPO pins (port A: M19/M20, port B: J16/K16).
# Open-drain LVCMOS25 (Vivado inserts the IOBUFs for the axi_iic IIC interface).
#==============================================================================
set_property PACKAGE_PIN M20 [get_ports iic_a_sda_io]
set_property PACKAGE_PIN M19 [get_ports iic_a_scl_io]
set_property PACKAGE_PIN J16 [get_ports iic_b_sda_io]
set_property PACKAGE_PIN K16 [get_ports iic_b_scl_io]
set_property IOSTANDARD LVCMOS25 [get_ports {iic_a_sda_io iic_a_scl_io iic_b_sda_io iic_b_scl_io}]
set_property SLEW SLOW           [get_ports {iic_a_sda_io iic_a_scl_io iic_b_sda_io iic_b_scl_io}]
set_property DRIVE 8             [get_ports {iic_a_sda_io iic_a_scl_io iic_b_sda_io iic_b_scl_io}]

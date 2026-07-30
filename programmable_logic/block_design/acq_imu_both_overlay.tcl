# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# acq_imu_both overlay -- sourced AFTER design_1_bd.tcl, it transforms the
# standard acquisition BD (design_1) in place into the both-ports-IMU variant:
#
#   * both cables run 64-ch (CIPO0 only): the two intan_spi_lvds_buffer cells are
#     swapped for the CIPO0-only variant, which drops the CIPO1 differential pair
#     so the second-CIPO pins (port A M19/M20, port B J16/K16) are free;
#   * an AXI IIC per cable takes those freed pins (single-ended I2C, 100 kHz) for
#     a BNO055 IMU -- axi_iic_a at 0x43D0_0000, axi_iic_b at 0x43D1_0000, the same
#     map the detect fabric uses, so pl_imu_detect.c works unchanged.
#
# Kept as an overlay (not a forked BD) so design_1_bd.tcl stays the single base
# source and the variant is only the diff.

current_bd_design design_1

#==============================================================================
# 1. Swap both LVDS buffers for the CIPO0-only variant
#==============================================================================
# Deleting the cells removes their nets; also drop the differential interface
# ports, whose intan_spi_diff abstraction still carries a CIPO1 pair we no longer
# drive. The data_generator intan_spi / intan_spi_b pins survive (reconnected
# below); the LVDS side is re-exposed as plain ports so no CIPO1 pins remain.
delete_bd_objs [get_bd_cells intan_spi_lvds_buffer_0] \
               [get_bd_cells intan_spi_lvds_buffer_1]
delete_bd_objs [get_bd_intf_ports spi_lvds_0] \
               [get_bd_intf_ports spi_lvds_1]

# Recreate the buffers (CIPO0-only) and reconnect the single-ended side.
create_bd_cell -type module -reference intan_spi_lvds_buffer_cipo0 intan_spi_lvds_buffer_0
create_bd_cell -type module -reference intan_spi_lvds_buffer_cipo0 intan_spi_lvds_buffer_1
connect_bd_intf_net [get_bd_intf_pins data_generator/intan_spi] \
                    [get_bd_intf_pins intan_spi_lvds_buffer_0/intan_spi]
connect_bd_intf_net [get_bd_intf_pins data_generator/intan_spi_b] \
                    [get_bd_intf_pins intan_spi_lvds_buffer_1/intan_spi]

# Plain LVDS external ports (names match acq_imu_both_pins.xdc). p/n legs are
# separate scalar ports, matching the flattened names the acq wrapper used.
# {suffix direction} -- sclk/csn/copi are design outputs, cipo0 is a design input.
foreach {suf dir} {sclk_p O sclk_n O csn_p O csn_n O copi_p O copi_n O cipo0_p I cipo0_n I} {
    create_bd_port -dir $dir spi_lvds_0_$suf
    connect_bd_net [get_bd_ports spi_lvds_0_$suf] [get_bd_pins intan_spi_lvds_buffer_0/spi_$suf]
    create_bd_port -dir $dir spi_lvds_1_$suf
    connect_bd_net [get_bd_ports spi_lvds_1_$suf] [get_bd_pins intan_spi_lvds_buffer_1/spi_$suf]
}

#==============================================================================
# 2. Graft the two AXI IIC masters (one per cable) onto GP0
#==============================================================================
# smartconnect_0 (from M_AXI_GP0) currently drives 3 masters
# (axi_lite_registers, axi_cdma, stim_top). Grow it to 5 for the two IICs.
set_property -dict [list CONFIG.NUM_MI {5}] [get_bd_cells smartconnect_0]

set iic_a [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_a]
set iic_b [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:2.1 axi_iic_b]
set_property -dict [list CONFIG.C_SCL_INERTIAL_DELAY {5} CONFIG.IIC_FREQ_KHZ {100}] $iic_a
set_property -dict [list CONFIG.C_SCL_INERTIAL_DELAY {5} CONFIG.IIC_FREQ_KHZ {100}] $iic_b

connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M03_AXI] [get_bd_intf_pins axi_iic_a/S_AXI]
connect_bd_intf_net [get_bd_intf_pins smartconnect_0/M04_AXI] [get_bd_intf_pins axi_iic_b/S_AXI]

# External IIC interfaces (Vivado inserts the open-drain IOBUFs).
make_bd_intf_pins_external [get_bd_intf_pins axi_iic_a/IIC]
set_property name iic_a [get_bd_intf_ports IIC_0]
make_bd_intf_pins_external [get_bd_intf_pins axi_iic_b/IIC]
set_property name iic_b [get_bd_intf_ports IIC_0]

# Same AXI clock + reset as the smartconnect the IICs hang off (175 MHz GP0 domain).
connect_bd_net -net clk_wiz_0_84M_clk_out2 \
    [get_bd_pins axi_iic_a/s_axi_aclk] [get_bd_pins axi_iic_b/s_axi_aclk]
connect_bd_net -net proc_sys_reset_175MHz_interconnect_aresetn \
    [get_bd_pins axi_iic_a/s_axi_aresetn] [get_bd_pins axi_iic_b/s_axi_aresetn]

# Address map -- identical to the detect fabric so firmware is unchanged.
assign_bd_address -offset 0x43D00000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs axi_iic_a/S_AXI/Reg] -force
assign_bd_address -offset 0x43D10000 -range 0x00010000 \
    -target_address_space [get_bd_addr_spaces processing_system7_0/Data] \
    [get_bd_addr_segs axi_iic_b/S_AXI/Reg] -force

validate_bd_design
save_bd_design

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# Build the standalone IMU-DETECT bitstream: minimal PS7 + imu_detect_top.
# Kept separate from the acquisition flow (create_vivado_project.tcl) so those
# pins can be single-ended I2C here and LVDS there. Produces detect_project.xsa.
set part_name "xc7z020clg400-1"
create_project detect_project ./vivado_detect -part $part_name -force
set_property target_language Verilog [current_project]

# no custom RTL: the two I2C masters are the Xilinx axi_iic IP (from the catalog)
# detect-only constraints (those pins are LVCMOS25 here, LVDS in the acq image).
# DETECT_XDC selects the normal or SDA/SCL-swapped pin map (build_detect.sh --swap).
set xdc "./programmable_logic/constraints/detect_pins.xdc"
if {[info exists ::env(DETECT_XDC)]} { set xdc $::env(DETECT_XDC) }
puts "DETECT_XDC=$xdc"
add_files -fileset constrs_1 $xdc

source programmable_logic/block_design/detect_bd.tcl

make_wrapper -files [get_files detect_bd.bd] -top
add_files -norecurse [get_property directory [current_project]]/[current_project].gen/sources_1/bd/detect_bd/hdl/detect_bd_wrapper.v
update_compile_order -fileset sources_1
set_property top detect_bd_wrapper [current_fileset]
generate_target all [get_files detect_bd.bd]

# OOC module runs first (imu_detect_top), then top synth (see build_bitstream.tcl note)
set ooc_runs [get_runs -filter {IS_SYNTHESIS && NAME != "synth_1"}]
foreach r $ooc_runs { reset_run $r }
reset_run synth_1
if {[llength $ooc_runs]} {
    launch_runs $ooc_runs -jobs 4
    foreach r $ooc_runs { wait_on_run $r }
}
launch_runs synth_1 -jobs 4
wait_on_run synth_1
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
write_hw_platform -fixed -include_bit -force -file ./vivado_detect/detect_project.xsa
puts "DETECT_BUILD_DONE xsa=./vivado_detect/detect_project.xsa"

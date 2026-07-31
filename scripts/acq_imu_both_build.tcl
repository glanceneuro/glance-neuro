# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
#
# Build the acq_imu_both fabric: the standard acquisition BD transformed by
# acq_imu_both_overlay.tcl (both cables 64-ch + an AXI IIC each for a BNO055).
# Kept separate from create_vivado_project.tcl so the second-CIPO pins can be
# single-ended I2C here and LVDS in the plain acq image. Produces
# vivado_acq_imu_both/acq_imu_both.xsa (with bitstream).

set project_name "acq_imu_both_project"
set project_dir  "./vivado_acq_imu_both"
set part_name    "xc7z020clg400-1"

create_project $project_name $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# RTL: same source tree as the acq build (includes intan_spi_lvds_buffer_cipo0.v).
puts "Adding source files..."
add_files -fileset sources_1 [glob ./programmable_logic/src/*.v]
add_files -fileset sources_1 [glob ./programmable_logic/src/*.sv]
update_compile_order -fileset sources_1

# Constraints: the full standard acq set MINUS intan_io.xdc (its LVDS lanes are
# replaced by the variant, which also drops CIPO1; the I2C lanes are in the
# variant too). Everything else -- DAC/UART/LED/digital-in
# pins AND zzz_clock_groups.xdc (the async 84/175 MHz declarations) -- is
# required: without the pin files 15 ports fail DRC, without the clock groups
# every cross-domain path is scored as a real violation.
puts "Adding variant constraints..."
add_files -fileset constrs_1 ./programmable_logic/constraints/variants/acq_imu_both_pins.xdc
foreach f [lsort [glob ./programmable_logic/constraints/*.xdc]] {
    set base [file tail $f]
    if {$base eq "intan_io.xdc"} { continue }
    add_files -fileset constrs_1 $f
}

# Custom Intan SPI interface IP.
set_property ip_repo_paths ./programmable_logic/ip/intan_spi_interface_lib [current_project]
update_ip_catalog

# Base acquisition BD, then the IMU-both overlay transform.
puts "Creating block design (base acq + acq_imu_both overlay)..."
source programmable_logic/block_design/design_1_bd.tcl
source programmable_logic/block_design/acq_imu_both_overlay.tcl

puts "Creating HDL wrapper..."
make_wrapper -files [get_files design_1.bd] -top
add_files -norecurse [get_property directory [current_project]]/[current_project].gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
update_compile_order -fileset sources_1
set_property top design_1_wrapper [current_fileset]
generate_target all [get_files design_1.bd]

# Synthesis: OOC block-design modules FIRST (each to completion), then the top.
# Same rationale as build_bitstream.tcl -- a stale child DCP stitches in silently
# otherwise. Reset every synthesis run so all modules re-synthesize from source.
set ooc_runs [get_runs -filter {IS_SYNTHESIS && NAME != "synth_1"}]
foreach r $ooc_runs { reset_run $r }
reset_run synth_1
if {[llength $ooc_runs]} {
    launch_runs $ooc_runs -jobs 8
    foreach r $ooc_runs { wait_on_run $r }
}
launch_runs synth_1 -jobs 8
wait_on_run synth_1

# Post-route hold fixing. The variant's extra IICs + cipo0-only buffers shift
# placement enough to push the LVDS CIPO0 input-capture path marginally hold-
# negative (~50 ps); the plain acq build clears the same path at +0.12 ns without
# help. Enable the post-route phys_opt step so hold closes, not just setup.
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

# Fail loudly if implementation did not finish with a written bitstream.
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "impl_1 did not complete (PROGRESS [get_property PROGRESS [get_runs impl_1]], STATUS [get_property STATUS [get_runs impl_1]])"
}

write_hw_platform -fixed -include_bit -force -file $project_dir/acq_imu_both.xsa
puts "ACQ_IMU_BOTH_BUILD_DONE xsa=$project_dir/acq_imu_both.xsa"

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Rice University
#
# Generic Vivado build for an acq_imu_* fabric variant. Invoked by
# scripts/build_fabric.py (which first regenerates the variant's overlay + pin
# XDC), never by hand:
#   vivado -mode batch -source scripts/build_fabric.tcl -tclargs <variant>
#
# Produces vivado_<variant>/<variant>.xsa (with bitstream). Same flow as the
# original acq_imu_both_build.tcl, with the variant name lifted to an argument.

if {$argc < 1} { error "usage: build_fabric.tcl <variant> (e.g. acq_imu_port_a)" }
set variant     [lindex $argv 0]
set project_name "${variant}_project"
set project_dir  "./vivado_${variant}"
set part_name    "xc7z020clg400-1"

set overlay "./programmable_logic/block_design/${variant}_overlay.tcl"
set pins    "./programmable_logic/constraints/variants/${variant}_pins.xdc"
foreach f [list $overlay $pins] {
    if {![file exists $f]} { error "missing $f -- run scripts/build_fabric.py $variant first" }
}

create_project $project_name $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# RTL: same source tree as the acq build (includes intan_spi_lvds_buffer_cipo0.v).
puts "Adding source files..."
add_files -fileset sources_1 [glob ./programmable_logic/src/*.v]
add_files -fileset sources_1 [glob ./programmable_logic/src/*.sv]
update_compile_order -fileset sources_1

# Constraints: the full standard acq set MINUS intan_io.xdc (LVDS lanes replaced
# by the variant) and detect_pins.xdc (I2C lanes folded into the variant), PLUS
# the generated variant pin XDC. Everything else -- DAC/UART/LED/digital-in pins
# AND zzz_clock_groups.xdc (async 84/175 MHz) -- is required: without the pin
# files ports fail DRC, without the clock groups every cross-domain path is scored
# as a real violation. Both fail only at the END of a ~15-min impl.
puts "Adding variant + standard constraints..."
add_files -fileset constrs_1 $pins
foreach f [lsort [glob ./programmable_logic/constraints/*.xdc]] {
    set base [file tail $f]
    if {$base eq "intan_io.xdc" || $base eq "detect_pins.xdc"} { continue }
    add_files -fileset constrs_1 $f
}

# Custom Intan SPI interface IP.
set_property ip_repo_paths ./programmable_logic/ip/intan_spi_interface_lib [current_project]
update_ip_catalog

# Base acquisition BD, then the generated variant overlay transform.
puts "Creating block design (base acq + ${variant} overlay)..."
source programmable_logic/block_design/design_1_bd.tcl
source $overlay

puts "Creating HDL wrapper..."
make_wrapper -files [get_files design_1.bd] -top
add_files -norecurse [get_property directory [current_project]]/[current_project].gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
update_compile_order -fileset sources_1
set_property top design_1_wrapper [current_fileset]
generate_target all [get_files design_1.bd]

# Synthesis: OOC block-design modules FIRST (each to completion), then the top.
# A stale child DCP stitches in silently otherwise. Reset every run so all modules
# re-synthesize from source.
set ooc_runs [get_runs -filter {IS_SYNTHESIS && NAME != "synth_1"}]
foreach r $ooc_runs { reset_run $r }
reset_run synth_1
if {[llength $ooc_runs]} {
    launch_runs $ooc_runs -jobs 8
    foreach r $ooc_runs { wait_on_run $r }
}
launch_runs synth_1 -jobs 8
wait_on_run synth_1

# Post-route hold fixing. The variant's extra IIC(s) + cipo0-only buffer(s) shift
# placement enough to push the LVDS CIPO0 input-capture path marginally hold-
# negative (~50 ps on acq_imu_both); the plain acq build clears it at +0.12 ns.
# Enable post-route phys_opt so hold closes, not just setup.
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "impl_1 did not complete (PROGRESS [get_property PROGRESS [get_runs impl_1]], STATUS [get_property STATUS [get_runs impl_1]])"
}

write_hw_platform -fixed -include_bit -force -file $project_dir/${variant}.xsa
puts "FABRIC_BUILD_DONE variant=$variant xsa=$project_dir/${variant}.xsa"

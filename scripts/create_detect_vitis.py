# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University
#
# Build the minimal IMU-DETECT Vitis app (single core, lwIP) from the detect
# XSA. Separate workspace from the acquisition build.

import vitis

client = vitis.create_client()
client.set_workspace(path="vitis_detect")

advanced_options = client.create_advanced_options_dict(dt_overlay="0")

platform = client.create_platform_component(
    name="detect-platform",
    hw_design="./vivado_detect/detect_project.xsa",
    os="standalone",
    cpu="ps7_cortexa9_0",
    domain_name="standalone_ps7_cortexa9_0",
    generate_dtb=False,
    advanced_options=advanced_options,
    compiler="gcc")

domain = platform.get_domain(name='standalone_ps7_cortexa9_0')
domain.set_config('lib', lib_name='xiltimer', param='XILTIMER_tick_timer', value='ps7_scutimer_0')
domain.set_lib('lwip220')
domain.set_config('lib', lib_name='lwip220', param='lwip220_no_sys_no_timers', value='false')
# xilffs (FatFs) for reading bitstream files off the SD card in the deferred-load
# path (pl_loader.c). Short 8.3 names only, so no long-filename support needed.
domain.set_lib('xilffs')

app = client.create_app_component(
    name="klab-detect",
    platform="./vitis_detect/detect-platform/export/detect-platform/detect-platform.xpfm",
    domain="standalone_ps7_cortexa9_0")
app = client.get_component(name="klab-detect")
app.import_files(from_loc="firmware", files=['src-detect', 'include'], is_skip_copy_sources=True)
app.set_app_config('USER_INCLUDE_DIRECTORIES', '../../../firmware/include')
app.set_app_config('USER_COMPILE_OPTIMIZATION_LEVEL', '-O2')
lscript = app.get_ld_script()
lscript.update_memory_region(name='ps7_ddr_0_memory_0', base_address='0x100000', size='0x1ff00000')

platform.build()
app = client.get_component(name="klab-detect")
app.build()

vitis.dispose()
print("DETECT_VITIS_DONE")

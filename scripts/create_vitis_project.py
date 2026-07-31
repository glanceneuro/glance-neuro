# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Caleb Kemere, Reet Sinha, Allen Mikhailov, Rice University

import vitis
import glob
import os

client = vitis.create_client()
client.set_workspace(path="vitis_workspace")

advanced_options = client.create_advanced_options_dict(dt_overlay="0")

# The platform's hardware handoff. The plain acq project uses the
# plain acq .xsa; the deferred-load build (build_acq_loader.sh) sets KLAB_XSA to
# the acq_imu_both superset (.xsa with the two AXI IICs) so the BSP carries XIic
# and pl_imu_detect.c links -- the firmware then probes IMUs on any fabric that
# has the IICs. The core acq peripherals sit at the same addresses in both, so
# the firmware still drives the plain acq / detect fabrics unchanged.
def _make_platform():
    return client.create_platform_component(name = "klab-platform",
            hw_design = os.environ.get("KLAB_XSA", "./vivado_project/klab_project.xsa"),
            os = "standalone",
            cpu = "ps7_cortexa9_0",
            domain_name = "standalone_ps7_cortexa9_0",
            generate_dtb = False,
            advanced_options = advanced_options,
            compiler = "gcc")

# Vitis 2025.1 toolchain race workaround (NOT a blind build retry). On the FIRST
# platform creation, Vitis fires two concurrent `empyro repo -st` writes to the
# shared _ide/.wsdata/.repo.yaml while the standalone domain's `empyro create_bsp`
# reads it -- so create_bsp intermittently sees a half-written schema and fails
# "Couldnt find the src directory for empty_application" (see _ide/logs/vitis.log).
# The .repo.yaml is complete afterward, so recreating the platform reads a SETTLED
# schema and succeeds -- exactly why running the platform command twice works.
# Create, confirm the standalone domain actually resolved, recreate if it raced.
platform = _make_platform()
domain = None
for _attempt in range(5):
    try:
        domain = platform.get_domain(name='standalone_ps7_cortexa9_0')
        break
    except Exception as _e:
        print(f"[create_vitis] platform raced the repo schema (attempt {_attempt+1}/5); recreating on the now-settled .repo.yaml ...")
        platform = _make_platform()
if domain is None:
    raise RuntimeError("platform creation kept racing the repo schema after 5 attempts")

domain.set_config('lib', lib_name='xiltimer', param='XILTIMER_tick_timer', value='ps7_scutimer_0')
domain.set_lib('lwip220')
domain.set_config('lib', lib_name='lwip220', param='lwip220_no_sys_no_timers', value='false')
# TX headroom: the zero-copy PBUF_REF send path takes one TX BD + a heap header-
# pbuf per packet; the defaults (64 descriptors / 128 KB heap) were occasionally
# exhausted during ISR-stall catch-up bursts, surfacing as rare udp_sendto ERR_MEM
# drops (v1.6 instrumentation: pbuf_alloc never failed, so it is NOT memp_n_pbuf).
domain.set_config('lib', lib_name='lwip220', param='lwip220_n_tx_descriptors', value='256')
domain.set_config('lib', lib_name='lwip220', param='lwip220_mem_size', value='262144')
# xilffs (FatFs) so core0 can read the acquisition fabric off the SD card in the
# deferred-boot model (src-loader/pl_loader.c). Short 8.3 names, no LFN needed.
domain.set_lib('xilffs')


domain = platform.add_domain(cpu = "ps7_cortexa9_1",os = "standalone",
                             name = "standalone_ps7_cortexa9_1", display_name = "standalone_ps7_cortexa9_1",
                             generate_dtb = False)
domain = platform.get_domain(name="standalone_ps7_cortexa9_1")

status = domain.set_config(option = "proc", param = "proc_extra_compiler_flags", 
                           value = " -O2 -g -Wall -Wextra -fno-tree-loop-distribute-patterns -DUSE_AMP=1")


app = client.create_app_component(name="klab-firmware",
                                  platform = "./vitis_workspace/klab-platform/export/klab-platform/klab-platform.xpfm",
                                  domain = "standalone_ps7_cortexa9_0")
app = client.get_component(name="klab-firmware")
status = app.import_files(from_loc="firmware", files=['src-core0', 'src-shared', 'src-loader', 'include'], is_skip_copy_sources=True)
app.set_app_config('USER_INCLUDE_DIRECTORIES','../../../firmware/include')
app.set_app_config('USER_COMPILE_OPTIMIZATION_LEVEL','-O3') # We can't make timing with the default -O0!!
lscript = app.get_ld_script()
lscript.update_memory_region(name='ps7_ddr_0_memory_0', base_address='0x100000', size='0x1ff00000')

app = client.create_app_component(name="klab-firmware-core1",
                                  platform = "./vitis_workspace/klab-platform/export/klab-platform/klab-platform.xpfm",
                                  domain = "standalone_ps7_cortexa9_1")
app = client.get_component(name="klab-firmware-core1")
status = app.import_files(from_loc="firmware", files=['src-core1', 'src-shared', 'include'], is_skip_copy_sources=True)
app.set_app_config('USER_INCLUDE_DIRECTORIES','../../../firmware/include')
app.set_app_config('USER_COMPILE_OPTIMIZATION_LEVEL','-O3') # We can't make timing with the default -O0!!
lscript = app.get_ld_script()
lscript.update_memory_region(name='ps7_ddr_0_memory_0', base_address='0x20000000', size='0x1f000000') # We'll put 1M of shared memory after this


# After creating the app:

# Append custom definitions
# with open(cmake_path, "a") as f:
#     f.write("""
# # === Custom UART and Memory Mapping ===
# set(UARTPS_NUM_DRIVER_INSTANCES "ps7_uart_1")
# set(UARTPS0_PROP_LIST "0xe0001000")
# list(APPEND TOTAL_UARTPS_PROP_LIST UARTPS0_PROP_LIST)
# set(IOMODULE_NUM_DRIVER_INSTANCES "")
# set(UARTLITE_NUM_DRIVER_INSTANCES "")
# set(UARTNS550_NUM_DRIVER_INSTANCES "")
# set(UARTPSV_NUM_DRIVER_INSTANCES "")
# """)


platform.build()

app = client.get_component(name="klab-firmware")
app.build()

app = client.get_component(name="klab-firmware-core1")
app.build()

vitis.dispose()

print("You can run 'bootgen -image scripts/boot.bif -o BOOT.bin -w' to generate the file for booting from flash.")

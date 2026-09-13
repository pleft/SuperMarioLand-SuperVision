cmake_minimum_required(VERSION 3.13)
set(CMAKE_C_STANDARD 11)
set(PICO_PLATFORM rp2040)
include(pico_sdk_import.cmake)
project(superpico_sml C CXX ASM)
pico_sdk_init()

add_executable(superpico_sml main.c)

# Run entirely from SRAM (like zwenergy's known-good firmware). The compacted
# ~224K image + code fits the RP2040's 264K SRAM; serving from SRAM avoids XIP
# flash latency, which was too slow for the SV bus (would not boot).
pico_set_binary_type(superpico_sml copy_to_ram)

pico_enable_stdio_usb(superpico_sml 0)
pico_enable_stdio_uart(superpico_sml 0)
target_compile_options(superpico_sml PRIVATE -Ofast)
target_link_libraries(superpico_sml pico_stdlib hardware_gpio pico_multicore)
pico_add_extra_outputs(superpico_sml)

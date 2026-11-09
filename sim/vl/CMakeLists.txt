# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
cmake_minimum_required(VERSION 3.20)
project(hh_hdmi_vl CXX)

# --timing uses C++20 coroutines (verilated_timing.cpp) -> require C++20.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(verilator REQUIRED)
include(${CMAKE_CURRENT_LIST_DIR}/../../../retrosim-build/tools/verilator.cmake)

# ---- Opt-in Verilator code-coverage instrumentation -------------------------
# VL_COVERAGE=ON appends --coverage-line + --coverage-toggle (+ the coverage.vlt
# focus filter) to EVERY retrosim_verilate() target, so the whole bench set can be re-run
# instrumented and merged with verilator_coverage. Default OFF. The coverage
# twins build into a SEPARATE dir (build/cov/) via vl/cov.ps1. Code coverage only
# -- SV covergroups are unsupported by Verilator. The two sub-flags rather than
# the --coverage alias: --coverage also turns on --coverage-user (SVA `cover`),
# and the benches author none.
option(VL_COVERAGE "Instrument the verilated models for code coverage" OFF)
set(VL_COV_ARGS "")
if(VL_COVERAGE)
  set(VL_COV_ARGS --coverage-line --coverage-toggle ${CMAKE_CURRENT_SOURCE_DIR}/coverage.vlt)
endif()

set(RTL ${CMAKE_CURRENT_SOURCE_DIR}/../../rtl)
set(SIM ${CMAKE_CURRENT_SOURCE_DIR}/..)

# Shared verilate args. --main makes Verilator emit the C++ main for these
# self-checking SV benches (their own initial blocks drive clk + $finish), so no
# hand-written sim_main.cpp is needed; empty_main.cpp only satisfies
# add_executable()'s require-a-source rule.
set(VL_COMMON
  --main --timing -DSIM --trace-depth 0
  -Wno-WIDTH -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC
  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-DECLFILENAME
  -Wno-MULTITOP -Wno-fatal
  --x-assign 0 --x-initial 0
)

# bench(name top [DEFINES <-Dfoo...>] SOURCES ...) -> a vl-<name> executable.
function(bench name top)
  cmake_parse_arguments(B "" "" "DEFINES;SOURCES" ${ARGN})
  add_executable(vl-${name} empty_main.cpp)
  retrosim_verilate(vl-${name}
    TOP_MODULE ${top}
    THREADS 1
    PREFIX V_${name}
    SOURCES ${B_SOURCES}
    VERILATOR_ARGS ${VL_COMMON} ${B_DEFINES} ${VL_COV_ARGS}
  )
endfunction()

# ---- The bench set: the same benches `ninja sim` (sim/gate.sh) runs ----------
set(ENC ${RTL}/hdmi_channel.sv ${RTL}/hdmi_packet.sv ${RTL}/hdmi_audio_src.sv ${RTL}/hdmi_encoder.sv)

# The encoder and everything under it.
bench(di_equiv    tb_di_equiv    SOURCES ${ENC} ${SIM}/tb_di_equiv.sv)
bench(di_bch      tb_di_bch      SOURCES ${ENC} ${SIM}/tb_di_bch.sv)
bench(sync_timing tb_sync_timing SOURCES ${ENC} ${SIM}/tb_sync_timing.sv)
bench(encoder_modes tb_encoder_modes SOURCES ${ENC} ${SIM}/tb_encoder_modes.sv)
bench(encoder_dvi tb_encoder_modes DEFINES -DHDMI_DVI_ONLY SOURCES ${ENC} ${SIM}/tb_encoder_modes.sv)
bench(channel tb_channel SOURCES ${RTL}/hdmi_channel.sv ${SIM}/tb_channel.sv)
bench(packet tb_packet SOURCES ${RTL}/hdmi_packet.sv ${SIM}/tb_packet.sv)

# The data-island content source alone.
bench(audio_src tb_audio_src SOURCES ${RTL}/hdmi_audio_src.sv ${SIM}/tb_audio_src.sv)
bench(spd tb_spd SOURCES ${RTL}/hdmi_audio_src.sv ${SIM}/tb_spd.sv)
bench(avi tb_avi SOURCES ${RTL}/hdmi_audio_src.sv ${SIM}/tb_avi.sv)

# DDC and CEC.
bench(edid     tb_edid_i2c     SOURCES ${RTL}/edid_i2c.sv ${SIM}/tb_edid_i2c.sv)
bench(edid_err tb_edid_i2c_err SOURCES ${RTL}/edid_i2c.sv ${SIM}/tb_edid_i2c_err.sv)
bench(edid_delayed tb_edid_i2c DEFINES -GSDA_DELAY_NS=90 -GBUS_QUARTER=4
      SOURCES ${RTL}/edid_i2c.sv ${SIM}/tb_edid_i2c.sv)
bench(cec      tb_cec          SOURCES ${RTL}/hdmi_cec.sv ${SIM}/tb_cec.sv)

# The serializers' generic models and the gearbox.
bench(serializer tb_serializer DEFINES -DPLL_SIM_FREE_RUN
      SOURCES ${RTL}/hdmi_serializer.sv ${SIM}/tb_serializer.sv)
bench(serializer_us tb_serializer_us SOURCES ${RTL}/hdmi_serializer_us.sv ${SIM}/tb_serializer_us.sv)
bench(gearbox       tb_gearbox       SOURCES ${RTL}/hdmi_gearbox_10to8.sv ${SIM}/tb_gearbox.sv)

# Exercise both portable clock models, as the Icarus gate does. These checks
# validate the models' frequencies, not the vendor PLL primitives in silicon.
bench(pll_video_60k tb_pll_video DEFINES -DPLL_SIM_FREE_RUN
      SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/../../pll/pll_video_60k.v ${SIM}/tb_pll_video.sv)
bench(pll_video_138k tb_pll_video DEFINES -DPLL_SIM_FREE_RUN
      SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/../../pll/pll_video_138k.v ${SIM}/tb_pll_video.sv)

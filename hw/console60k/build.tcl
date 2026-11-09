# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
set_device -name GW5AT-60B GW5AT-LV60PG484AC1/I0
set_option -output_base_name edid_probe
set_option -top_module edid_probe
set_option -verilog_std sysv2017
add_file -type verilog edid_probe.sv
add_file -type verilog ../../rtl/edid_i2c.sv
foreach file {uart_baud_dds uart_tx_core uart_rx_core} {
    add_file -type verilog ../../../hh-uart/rtl/$file.sv
}
add_file -type cst probe.cst
add_file -type sdc probe.sdc
run all

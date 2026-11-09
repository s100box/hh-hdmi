# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
create_clock -name sys_clk -period 20.000 [get_ports {sys_clk}]
# Asynchronous pads enter only their first synchronizer registers. The
# synchronizer's second stage and all ACK/data sampling remain normally timed.
set_false_path -from [get_ports {ddc_sda}] -to [get_regs {*sda_meta*}]
set_false_path -from [get_ports {uart_rxd}] -to [get_regs {*rxd_meta*}]
set_false_path -from [get_ports {hpd}] -to [get_regs {*hpd_s0*}]
set_false_path -from [get_ports {btn_rst_n}] -to [get_regs {*rst_meta*}]

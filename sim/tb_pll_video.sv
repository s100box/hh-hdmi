// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
//
// tb_pll_video -- the PLL_SIM_FREE_RUN branch of pll/pll_video_60k.v and
// pll/pll_video_138k.v (gate.sh compiles each in turn): lock high, the pixel
// clock at 74.25 MHz, the DDR bit clock at 371.25 MHz. The primitive branch
// requires vendor timing analysis and board qualification.
`timescale 1ns / 1ps
`default_nettype none

module tb_pll_video;
  wire clkout, clkoutd, lock;
  pll_video dut (
      .clkin  (1'b0),
      .clkout (clkout),
      .clkoutd(clkoutd),
      .lock   (lock)
  );

  integer errors = 0;
  realtime t0, t1;

  // Period of one clock, rising edge to rising edge, averaged over 100 cycles.
  task automatic check_period(input string name, input real want_ns, input bit is_pix);
    real got;
    if (is_pix) begin
      @(posedge clkout) t0 = $realtime;
      repeat (100) @(posedge clkout);
    end else begin
      @(posedge clkoutd) t0 = $realtime;
      repeat (100) @(posedge clkoutd);
    end
    t1  = $realtime;
    got = (t1 - t0) / 100.0;
    if (got < want_ns * 0.999 || got > want_ns * 1.001) begin
      $display("FAIL: %s period %.4f ns, want %.4f ns", name, got, want_ns);
      errors = errors + 1;
    end
  endtask

  initial begin
    #200;
    if (lock !== 1'b1) begin
      $display("FAIL: lock = %b", lock);
      errors = errors + 1;
    end
    check_period("clkout", 1000.0 / 74.25, 1'b1);
    check_period("clkoutd", 1000.0 / 371.25, 1'b0);
    if (errors == 0) $display("PASS: pll_video free-run clocks and lock");
    else $display("tb_pll_video: %0d error(s)", errors);
    $finish;
  end
endmodule

`default_nettype wire

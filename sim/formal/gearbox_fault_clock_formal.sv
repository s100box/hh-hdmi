// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
// Native Yosys timebase. A common reset request forces enough running clocks
// for both synchronous resets to be observed, even if pause_pix stays asserted.
module gearbox_fault_clock_formal #(
    parameter integer WORD_PHASE = 0
) (
    input wire pause_pix,
    input wire restart
);
  reg [4:0] phase = 0;
  reg [4:0] startup = 0;
  reg [5:0] steady = 0;
  wire reset_n = &startup;
  always @($global_clock) begin
    assert (phase <= 19);
    phase <= phase == 19 ? 0 : phase + 1'b1;
    if (restart) startup <= 0;
    else if (!reset_n) startup <= startup + 1'b1;
    if (!reset_n || pause_pix) steady <= 0;
    else if (!(&steady)) steady <= steady + 1'b1;
  end
  wire pixel_phase = phase == 0 || phase == 1 || phase == 5 || phase == 6 ||
                     phase == 10 || phase == 11 || phase == 15 || phase == 16;
  wire pix = pixel_phase && (!pause_pix || !reset_n);
  wire [1:0] word_phase = phase[1:0] + 2'(WORD_PHASE);
  wire word_clk = !word_phase[1];
  gearbox_fault_formal model (
      .pix          (pix),
      .word_clk     (word_clk),
      .reset_n      (reset_n),
      .stable_clocks(&steady)
  );
endmodule

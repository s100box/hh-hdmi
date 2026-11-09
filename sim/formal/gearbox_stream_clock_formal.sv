// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
// Read this small clock driver with Yosys's formal frontend: $global_clock is
// a Yosys construct. RTL and properties are elaborated separately by slang.
// One formal step is one time unit, so the fixed-rate model cannot stutter.
module gearbox_stream_clock_formal #(
    parameter integer WORD_PHASE   = 0,
    parameter integer PIX_RELEASE  = 31,
    parameter integer WORD_RELEASE = 31
) (
    input wire [9:0] symbol
);
  reg [4:0] phase = 0;
  reg [5:0] startup = 0;
  always @($global_clock) begin
    assert (phase <= 19);
    phase <= phase == 19 ? 0 : phase + 1'b1;
    if (!(&startup)) startup <= startup + 1'b1;
  end
  wire pix = phase == 0 || phase == 1 || phase == 5 || phase == 6 ||
             phase == 10 || phase == 11 || phase == 15 || phase == 16;
  wire [1:0] word_phase = phase[1:0] + 2'(WORD_PHASE);
  wire word_clk = !word_phase[1];
  gearbox_stream_formal model (
      .symbol      (symbol),
      .pix         (pix),
      .word_clk    (word_clk),
      .reset_pix_n (startup >= PIX_RELEASE),
      .reset_word_n(startup >= WORD_RELEASE)
  );
endmodule

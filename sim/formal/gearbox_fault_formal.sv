// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
// Digital cadence faults: an arbitrarily paused pixel clock, a continuously
// running word clock, and coordinated reset. Data during a clock fault is not
// promised; sticky fault reporting and bounded recovery are checked instead.
module gearbox_fault_formal (
    input wire logic pix,
    input wire logic word_clk,
    input wire logic reset_n,
    input wire logic stable_clocks
);
  wire aligned, slip;
  hdmi_gearbox_10to8 #(
      .LANES(1)
  ) dut (
      .clk_pix   (pix),
      .rst_pix_n (reset_n),
      .sym_i     (10'b0),
      .clk_word  (word_clk),
      .rst_word_n(reset_n),
      .word_o    (),
      .aligned_o (aligned),
      .slip_o    (slip)
  );
  logic [1:0] symbols;
  logic group_tag;
  always @(posedge pix) begin
    if (!reset_n) begin
      symbols   <= 0;
      group_tag <= 0;
    end else begin
      symbols <= symbols + 1'b1;
      if (symbols == 3) group_tag <= !group_tag;
    end
  end
  logic last_tag, ever_aligned;
  logic [3:0] quiet_words;
  logic past_valid = 0, saw_slip = 0, reset_after_slip = 0;
  always @(posedge word_clk) begin
    past_valid <= 1;
    if (slip) saw_slip <= 1;
    if (!reset_n) begin
      last_tag     <= 0;
      quiet_words  <= 0;
      ever_aligned <= 0;
      if (saw_slip) reset_after_slip <= 1;
    end else begin
      last_tag <= group_tag;
      if (last_tag != group_tag) quiet_words <= 0;
      else if (quiet_words < 10) quiet_words <= quiet_words + 1'b1;
      if (aligned) ever_aligned <= 1;
      assert (dut.cnt <= 4);
      if (ever_aligned && quiet_words == 10) assert (!aligned && slip);
      // The wrapper establishes 63 uninterrupted global time units at the
      // required ratio after the last reset/pause, sufficient for reacquisition.
      if (stable_clocks) assert (aligned);
      cover (slip && !aligned);
      cover (slip && aligned && stable_clocks);
      cover (reset_after_slip && aligned && !slip && stable_clocks);
`ifdef FORMAL_NEGATIVE
      assert (!slip);
`endif
    end
    if (past_valid) begin
      if (!$past(reset_n))
        assert (!slip && !aligned);
        else if ($past(slip)) assert (slip);
    end
  end
endmodule

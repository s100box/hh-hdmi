// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
// Prove the packing and byte-shift datapaths with arbitrary symbols. This job
// uses one clock for both domains: it establishes local datapath behavior, while
// the separate phase matrix checks ownership under the required 4:5 clocks.
module gearbox_data_formal (
    input wire logic       clk,
    input wire logic       rst_n,
    input wire logic [9:0] symbol
);
  logic past_valid = 0;
  always_ff @(posedge clk) past_valid <= 1;
  always_comb if (!past_valid) assume (!rst_n);
  hdmi_gearbox_10to8 #(
      .LANES(1)
  ) dut (
      .clk_pix   (clk),
      .rst_pix_n (rst_n),
      .sym_i     (symbol),
      .clk_word  (clk),
      .rst_word_n(rst_n),
      .word_o    (),
      .aligned_o (),
      .slip_o    ()
  );
  logic [39:0] building;
  logic [ 1:0] index;
  logic [ 3:0] collected;
  logic [39:0] expected_word;
  logic [31:0] expected_shift;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      index          <= 0;
      collected      <= 0;
      expected_word  <= 0;
      expected_shift <= 0;
    end else begin
      index     <= index + 1'b1;
      collected <= {collected[2:0], 1'b1};
      building  <= {symbol, building[39:10]};
      if (dut.aligned_o && dut.cnt == 0) begin
        expected_word  <= dut.rsel ? dut.buf1 : dut.buf0;
        expected_shift <= (dut.rsel ? dut.buf1[39:8] : dut.buf0[39:8]);
      end else if (dut.aligned_o) begin
        expected_word  <= {32'd0, expected_shift[7:0]};
        expected_shift <= expected_shift >> 8;
      end else expected_word <= 0;
    end
    if (past_valid) begin
      assert (dut.n == index);
      assert (dut.word_o == expected_word[7:0]);
      if (rst_n && $past(rst_n) && $past(dut.aligned_o)) assert (dut.sh == expected_shift);
      if (rst_n && $past(rst_n) && $past(dut.n) == 3 && (&collected)) begin
        if ($past(dut.wsel))
          assert (dut.buf1 == building);
          else assert (dut.buf0 == building);
      end
      if (rst_n && $past(rst_n) && $past(dut.slip_o)) assert (dut.slip_o);
      cover (rst_n && dut.aligned_o && dut.word_o != 0);
      cover (rst_n && dut.slip_o);
`ifdef FORMAL_NEGATIVE
      if (rst_n && $past(rst_n) && dut.aligned_o) assert (dut.word_o == 0);
`endif
    end
  end
endmodule

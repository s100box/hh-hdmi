// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
// Independent serial-bit queue, driven by arbitrary complete input symbols.
// The clock wrapper supplies the exact 4:5 rate and startup reset contract.
module gearbox_stream_formal (
    input wire logic       pix,
    input wire logic       word_clk,
    input wire logic       reset_pix_n,
    input wire logic       reset_word_n,
    input wire logic [9:0] symbol
);
  wire [7:0] byte_out;
  wire aligned, slip;
  hdmi_gearbox_10to8 #(
      .LANES(1)
  ) dut (
      .clk_pix   (pix),
      .rst_pix_n (reset_pix_n),
      .sym_i     (symbol),
      .clk_word  (word_clk),
      .rst_word_n(reset_word_n),
      .word_o    (byte_out),
      .aligned_o (aligned),
      .slip_o    (slip)
  );
  logic [39:0] building, completed;
  logic [1:0] pixel_index;
  logic groups, produced;
  always @(posedge pix) begin
    if (!reset_pix_n) begin
      pixel_index <= 0;
      groups      <= 0;
      produced    <= 0;
      building    <= 0;
      completed   <= 0;
    end else begin
      building    <= {symbol, building[39:10]};
      pixel_index <= pixel_index + 1'b1;
      if (pixel_index == 3) begin
        completed <= {symbol, building[39:10]};
        groups    <= groups + 1'b1;
        produced  <= 1;
      end
    end
  end
  // Inductive relationships hold between clock edges too: storage changes
  // only on its owning clock. These are assertions, never environment cuts.
  always_comb begin
    if (reset_pix_n) begin
      assert (dut.n == pixel_index);
      assert (dut.wsel == groups);
      assert (dut.grp_tgl == groups);
      case (pixel_index)
        1: assert (dut.acc[9:0] == building[39:30]);
        2: assert (dut.acc[19:0] == building[39:20]);
        3: assert (dut.acc == building[39:10]);
        default: begin
        end
      endcase
      if (produced) assert (completed == (dut.wsel ? dut.buf0 : dut.buf1));
    end
  end
  logic [39:0] remaining;
  logic [7:0] expected_byte;
  logic loaded_group;
  logic [2:0] group_pipe, position;
  logic started;
  logic [1:0] transferred;
  logic emitted = 0, loaded = 0;
  always_comb
    if (reset_word_n) begin
      assert (dut.cnt <= 4);
      assert (!slip);
      assert ({dut.tgl_prev, dut.tgl_sync, dut.tgl_meta} == group_pipe);
      assert (aligned == started);
      if (started) assert (dut.cnt == position);
      if (loaded) begin
        assert (aligned);
        assert (dut.sh == remaining[31:0]);
        assert (dut.rsel == loaded_group);
      end
    end
  always @(posedge word_clk) begin
    // The reference byte cadence follows the observed group event, then emits
    // exactly five bytes per group. It never uses the DUT's load counter.
    group_pipe <= {group_pipe[1:0], groups};
    if (!reset_word_n) begin
      emitted     <= 0;
      loaded      <= 0;
      started     <= 0;
      position    <= 0;
      transferred <= 0;
    end else begin
      if (!started) begin
        if (group_pipe[1] != group_pipe[2]) begin
          started  <= 1;
          position <= 0;
        end
      end else position <= position == 4 ? 0 : position + 1'b1;
      if (emitted) assert (byte_out == expected_byte);
      emitted <= 1;
      if (started && position == 0) begin
        if (loaded) assert (groups != loaded_group);
        assert (produced);
        assert (dut.rsel != dut.wsel);
        loaded <= 1;
        if (transferred < 3) transferred <= transferred + 1'b1;
        loaded_group  <= groups;
        expected_byte <= completed[7:0];
        remaining     <= completed >> 8;
      end else if (started) begin
        expected_byte <= remaining[7:0];
        remaining     <= remaining >> 8;
      end else expected_byte <= 0;
      cover (transferred == 3 && byte_out == 8'hA5);
`ifdef FORMAL_NEGATIVE
      if (loaded) assert (byte_out == 0);
`endif
    end
  end
endmodule

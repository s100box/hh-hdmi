// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
// FIFO preservation at accepted-group boundaries. Packet slots are separated
// by 32 pixels; absent slots may fill the FIFO and exercise documented drops.
module audio_formal (
    input wire logic        clk,
    input wire logic        rst_n,
    input wire logic        slot,
    input wire logic        field_end,
    input wire logic [15:0] left,
    input wire logic [15:0] right
);
  logic past_valid = 0;
  logic [4:0] phase;
  always_ff @(posedge clk) begin
    past_valid <= 1;
    if (!rst_n) phase <= 0;
    else phase <= phase + 1'b1;
  end
  always_comb if (!past_valid) assume (!rst_n);
  wire enable_packet = slot && phase == 0;
  hdmi_audio_src dut (
      .clk_pix        (clk),
      .rst_n          (rst_n),
      .audio_l        (left),
      .audio_r        (right),
      .aud_rate       (2'd0),
      .aud_depth      (2'd0),
      .vic            (8'd4),
      .aud_div_max_i  (13'd4),
      .aud_div_frac_i (8'd0),
      .packet_enable  (enable_packet),
      .counter        (phase),
      .video_field_end(field_end),
      .header         (),
      .subs           ()
  );
  logic [3:0] written, read;
  logic [127:0] reference[8];
  logic [7:0] initialized;
  wire [3:0] used = written - read;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      written     <= 0;
      read        <= 0;
      initialized <= 0;
    end else begin
      if (dut.do_push) begin
        reference[written[2:0]]   <= dut.grp_word;
        initialized[written[2:0]] <= 1;
        written                   <= written + 1'b1;
      end
      if (dut.grp_pop) begin
        assert (used != 0);
        assert (initialized[read[2:0]]);
        assert ({dut.sl[0], dut.sr[0], dut.sl[1], dut.sr[1],
                 dut.sl[2], dut.sr[2], dut.sl[3], dut.sr[3]} == reference[read[2:0]]);
        read <= read + 1'b1;
      end
    end
    if (past_valid) begin
      assert (dut.wr_ptr == written[2:0]);
      assert (dut.rd_ptr == read[2:0]);
      assert (dut.fifo_count == used);
      assert (used <= 8);
      if (rst_n && $past(rst_n) && !$past(enable_packet)) begin
        assert ({dut.sl[0], dut.sr[0], dut.sl[1], dut.sr[1],
                 dut.sl[2], dut.sr[2], dut.sl[3], dut.sr[3]} ==
                $past({dut.sl[0], dut.sr[0], dut.sl[1], dut.sr[1], dut.sl[2], dut.sr[2], dut.sl[3],
                       dut.sr[3]}));
      end
      cover (rst_n && dut.grp_pop);
      cover (rst_n && dut.fifo_full && dut.grp_push);
      cover (rst_n && written[3] && read[3]);
`ifdef FORMAL_NEGATIVE
      assert (used == 0);
`endif
    end
  end
  for (genvar i = 0; i < 8; i++) begin : g_memory
    wire [2:0] distance = 3'(i) - read[2:0];
    always_ff @(posedge clk)
      if (past_valid) begin
        if (initialized[i]) assert (dut.afifo[i] == reference[i]);
        if (4'(distance) < used) assert (initialized[i]);
      end
  end
endmodule

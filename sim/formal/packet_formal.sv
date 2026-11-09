// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
// Compare both pipeline configurations and check the syndrome of on-wire codewords.
module packet_formal (
    input wire logic         clk,
    input wire logic         rst_n,
    input wire logic         active,
    input wire logic [ 23:0] header,
    input wire logic [223:0] subs
);
  logic past_valid = 0;
  always_ff @(posedge clk) past_valid <= 1;
  always_comb begin
    if (!past_valid) assume (!rst_n);
    if (!rst_n) assume (!active);
  end
  wire [8:0] direct_data, piped_data;
  wire [4:0] direct_count, piped_count;
  hdmi_packet #(
      .DI_PIPE(0)
  ) u_direct (
      .clk_pix           (clk),
      .rst_n             (rst_n),
      .data_island_period(active),
      .header            (header),
      .subs              (subs),
      .packet_data       (direct_data),
      .counter           (direct_count)
  );
  hdmi_packet #(
      .DI_PIPE(1)
  ) u_piped (
      .clk_pix           (clk),
      .rst_n             (rst_n),
      .data_island_period(active),
      .header            (header),
      .subs              (subs),
      .packet_data       (piped_data),
      .counter           (piped_count)
  );
  function automatic logic [7:0] step(input logic [7:0] crc, input logic bit_in);
    // Right-shift feedback mask for G(x)=x^8+x^7+x^6+1.
    // Feed payload AND transmitted parity, first-transmitted bit first.
    step = {1'b0, crc[7:1]} ^ ({8{crc[0] ^ bit_in}} & 8'h83);
  endfunction
  logic [7:0] residue[5];
  wire [7:0] header_next = step(residue[4], direct_data[0]);
  wire [7:0] sub_next[4];
  for (genvar k = 0; k < 4; k++) begin : g_sub
    assign sub_next[k] = step(step(residue[k], direct_data[1+k]), direct_data[5+k]);
  end
  always_ff @(posedge clk) begin
    if (!rst_n || !active) begin
      for (int k = 0; k < 5; k++) residue[k] <= 0;
    end else begin
      residue[4] <= header_next;
      for (int k = 0; k < 4; k++) residue[k] <= sub_next[k];
      if (direct_count == 31) begin
        assert (header_next == 0);
        for (int k = 0; k < 4; k++) assert (sub_next[k] == 0);
      end
    end
    if (past_valid && rst_n && $past(rst_n)) begin
      assert (direct_count == piped_count);
      assert (piped_data == $past(direct_data));
      assert (u_piped.bcnt == $past(u_direct.bcnt));
      for (int k = 0; k < 5; k++) assert (u_piped.parity[k] == $past(u_direct.parity[k]));
      assert (u_direct.bsel == (32'd1 << direct_count));
      assert (u_direct.bcnt == direct_count);
      assert (u_direct.blt24 == (direct_count < 24));
      assert (u_direct.blt28 == (direct_count < 28));
      // During parity transmission the independent on-wire syndrome shifts
      // toward zero. These strengthening invariants avoid a full-packet
      // induction window while retaining the final zero-residue assertion.
      assert (residue[4] == (u_direct.parity[4] >>
              (direct_count < 24 ? 0 : int'(direct_count)-24)));
      for (int k = 0; k < 4; k++)
      assert (residue[k] == (u_direct.parity[k] >>
                (direct_count < 28 ? 0 : 2*(int'(direct_count)-28))));
      cover (active && direct_count == 31 && header_next == 0);
`ifdef FORMAL_NEGATIVE
      assert (direct_count == 0);  // false: a packet advances
`endif
    end
  end
endmodule

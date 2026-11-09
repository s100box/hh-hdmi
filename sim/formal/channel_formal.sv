// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
// Decode the emitted symbols independently of the encoder's intermediate terms.
module channel_formal (
    input wire logic       clk,
    input wire logic [7:0] video,
    input wire logic [3:0] island,
    input wire logic [1:0] control,
    input wire logic [2:0] mode
);
  logic past_valid = 0;
  always_ff @(posedge clk) past_valid <= 1;
  always_comb if (!past_valid) assume (mode == 0);  // no reset pin: seed disparity

  function automatic logic [7:0] decode(input logic [9:0] symbol);
    logic [7:0] qm;
    qm        = symbol[7:0] ^ {8{symbol[9]}};
    decode[0] = qm[0];
    for (int i = 1; i < 8; i++) decode[i] = qm[i] ^ qm[i-1] ^ !symbol[8];
  endfunction
  function automatic integer ones(input logic [9:0] symbol);
    ones = 0;
    for (int i = 0; i < 10; i++) ones += int'(symbol[i]);
  endfunction
  function automatic logic [9:0] ctl(input logic [1:0] bits_in);
    case (bits_in)
      0: ctl = 10'b1101010100;
      1: ctl = 10'b0010101011;
      2: ctl = 10'b0101010100;
      default: ctl = 10'b1010101011;
    endcase
  endfunction
  function automatic logic [9:0] terc(input logic [3:0] nibble);
    // HDMI table 5-2; array indexed by decoded nibble, not encoder state.
    case (nibble)
      0: terc = 10'b1010011100;
      1: terc = 10'b1001100011;
      2: terc = 10'b1011100100;
      3: terc = 10'b1011100010;
      4: terc = 10'b0101110001;
      5: terc = 10'b0100011110;
      6: terc = 10'b0110001110;
      7: terc = 10'b0100111100;
      8: terc = 10'b1011001100;
      9: terc = 10'b0100111001;
      10: terc = 10'b0110011100;
      11: terc = 10'b1011000110;
      12: terc = 10'b1010001110;
      13: terc = 10'b1001110001;
      14: terc = 10'b0101100011;
      default: terc = 10'b1011000011;
    endcase
  endfunction
  for (genvar lane = 0; lane < 3; lane++) begin : g_lane
    wire [9:0] symbol;
    hdmi_channel #(
        .CN(lane)
    ) dut (
        .clk_pix     (clk),
        .video_data  (video),
        .island_data (island),
        .control_data(control),
        .mode        (mode),
        .tmds        (symbol)
    );
    always_ff @(posedge clk)
      if (past_valid) begin
        assert ($signed(dut.acc) >= -8 && $signed(dut.acc) <= 8);
        assert (!dut.acc[0]);
        case ($past(
            mode
        ))
          1: begin
            assert (decode(symbol) == $past(video));
            assert (int'($signed(
                dut.acc
            )) == int'($signed(
                $past(dut.acc)
            )) + 2 * ones(
                symbol
            ) - 10);
          end
          2: assert (symbol == (lane == 1 ? 10'b0100110011 : 10'b1011001100));
          3: assert (symbol == terc($past(island)));
          4: assert (symbol == (lane == 0 ? terc({2'b11, $past(control)}) : 10'b0100110011));
          default: assert (symbol == ctl($past(control)));
        endcase
        if ($past(mode) != 1) assert (dut.acc == 0);
        cover ($past(mode) == 1 && $past(video) == 8'hA5 && dut.acc != 0);
        cover ($past(mode) == 3 && $past(island) == 15);
`ifdef FORMAL_NEGATIVE
        if ($past(mode) == 1) assert (symbol == 0);
`endif
      end
  end
endmodule

// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// hdmi_channel.sv  --  one HDMI TMDS lane: video + control + data-island coding.
//
// The DVI 8b/10b TMDS video coding plus the four extra HDMI line states
// needed for data islands. `mode` selects which 10-bit code this lane emits:
//
//   0  control period      -> 2-bit control symbol  (HSYNC/VSYNC + CTL0..3)
//   1  video data period   -> TMDS 8b/10b of `video_data` (DC-balanced)
//   2  video guard band    -> fixed per-lane symbol (HDMI 5.2.2.1)
//   3  data island period  -> TERC4 of the 4-bit `island_data` (HDMI 5.4.3)
//   4  data island guard   -> fixed per-lane symbol (HDMI 5.2.3.3)
//
// The running-disparity accumulator is held at 0 outside the video period, as
// the spec requires. The 8b/10b algorithm is HDMI 5.4.4.1 (DVI 1.0 3.2.2); the
// control, TERC4 and guard-band tables are the spec's.
//----------------------------------------------------------------------------
`default_nettype none

module hdmi_channel #(
    parameter int CN = 0  // lane number 0(B) / 1(G) / 2(R)
) (
    input  wire logic       clk_pix,
    input  wire logic [7:0] video_data,
    input  wire logic [3:0] island_data,
    input  wire logic [1:0] control_data,  // {vsync/CTLn high, hsync/CTLn low}
    input  wire logic [2:0] mode,
    output logic      [9:0] tmds
);

  // ── TMDS 8b/10b (HDMI 5.4.4.1): transition minimization, then DC balance ──
  logic [3:0] n1d;
  logic       use_xnor;
  assign n1d = video_data[0] + video_data[1] + video_data[2] + video_data[3]
             + video_data[4] + video_data[5] + video_data[6] + video_data[7];
  assign use_xnor = (n1d > 4) || ((n1d == 4) && (video_data[0] == 1'b0));

  logic [8:0] q_m;
  always_comb begin
    q_m[0] = video_data[0];
    for (int gi = 1; gi < 8; gi++) begin
      q_m[gi] = use_xnor ? (q_m[gi-1] ~^ video_data[gi]) : (q_m[gi-1] ^ video_data[gi]);
    end
    q_m[8] = ~use_xnor;
  end

  logic [3:0] n1q, n0q;
  assign n1q = q_m[0] + q_m[1] + q_m[2] + q_m[3] + q_m[4] + q_m[5] + q_m[6] + q_m[7];
  assign n0q = 4'd8 - n1q;

  logic signed [4:0] acc;  // running disparity
  logic [9:0] video_coding;
  logic signed [4:0] acc_next;
  always_comb begin
    if (acc == 5'sd0 || n1q == n0q) begin
      video_coding[9]   = ~q_m[8];
      video_coding[8]   = q_m[8];
      video_coding[7:0] = q_m[8] ? q_m[7:0] : ~q_m[7:0];
      if (q_m[8] == 1'b0) acc_next = acc + (n0q - n1q);
      else acc_next = acc + (n1q - n0q);
    end else if ((acc > 0 && n1q > n0q) || (acc < 0 && n0q > n1q)) begin
      video_coding[9]   = 1'b1;
      video_coding[8]   = q_m[8];
      video_coding[7:0] = ~q_m[7:0];
      acc_next          = acc + {3'b0, q_m[8], 1'b0} + (n0q - n1q);
    end else begin
      video_coding[9]   = 1'b0;
      video_coding[8]   = q_m[8];
      video_coding[7:0] = q_m[7:0];
      acc_next          = acc - {3'b0, ~q_m[8], 1'b0} + (n1q - n0q);
    end
  end
  // Disparity only accumulates during the video period (mode 1).
  always_ff @(posedge clk_pix) acc <= (mode != 3'd1) ? 5'sd0 : acc_next;

  // ── Control symbols (HDMI 5.4.2) ─────────────────────────────────────────
  logic [9:0] control_coding;
  always_comb begin
    case (control_data)
      2'b00:   control_coding = 10'b1101010100;
      2'b01:   control_coding = 10'b0010101011;
      2'b10:   control_coding = 10'b0101010100;
      default: control_coding = 10'b1010101011;  // 2'b11
    endcase
  end

  // ── TERC4 (HDMI 5.4.3): 4-bit island data -> 10-bit ──────────────────────
  logic [9:0] terc4_coding;
  always_comb begin
    case (island_data)
      4'h0:    terc4_coding = 10'b1010011100;
      4'h1:    terc4_coding = 10'b1001100011;
      4'h2:    terc4_coding = 10'b1011100100;
      4'h3:    terc4_coding = 10'b1011100010;
      4'h4:    terc4_coding = 10'b0101110001;
      4'h5:    terc4_coding = 10'b0100011110;
      4'h6:    terc4_coding = 10'b0110001110;
      4'h7:    terc4_coding = 10'b0100111100;
      4'h8:    terc4_coding = 10'b1011001100;
      4'h9:    terc4_coding = 10'b0100111001;
      4'hA:    terc4_coding = 10'b0110011100;
      4'hB:    terc4_coding = 10'b1011000110;
      4'hC:    terc4_coding = 10'b1010001110;
      4'hD:    terc4_coding = 10'b1001110001;
      4'hE:    terc4_coding = 10'b0101100011;
      default: terc4_coding = 10'b1011000011;  // 4'hF
    endcase
  end

  // ── Video guard band (HDMI 5.2.2.1) ──────────────────────────────────────
  localparam logic [9:0] VGUARD = (CN == 1) ? 10'b0100110011 : 10'b1011001100;

  // ── Data island guard band (HDMI 5.2.3.3) ────────────────────────────────
  // Lanes 1/2 are fixed; lane 0 carries HSYNC/VSYNC as a TERC4-like symbol.
  logic [9:0] data_guard;
  generate
    if (CN == 1 || CN == 2) begin : g_dguard_fixed
      assign data_guard = 10'b0100110011;
    end else begin : g_dguard_ch0
      assign data_guard = (control_data == 2'b00) ? 10'b1010001110
                        : (control_data == 2'b01) ? 10'b1001110001
                        : (control_data == 2'b10) ? 10'b0101100011
                        :                           10'b1011000011;
    end
  endgenerate

  always_ff @(posedge clk_pix) begin
    case (mode)
      3'd0:    tmds <= control_coding;
      3'd1:    tmds <= video_coding;
      3'd2:    tmds <= VGUARD;
      3'd3:    tmds <= terc4_coding;
      3'd4:    tmds <= data_guard;
      default: tmds <= control_coding;
    endcase
  end

endmodule

`default_nettype wire

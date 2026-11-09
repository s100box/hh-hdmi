// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_spd.sv -- the Source Product Description InfoFrame comes from the
// SPD_VENDOR / SPD_PRODUCT / SPD_SDI parameters of hdmi_audio_src.
//
// Three instances, each run until it emits its SPD packet (type 0x83):
//   * the defaults ("hh-hdmi", "HDMI source", SDI 0x00);
//   * a game console's values ("Atari", "Atari 2600", SDI 0x08 Game), also
//     checked byte for byte against a hand-assembled SPD body;
//   * a 16-character product and an 8-character vendor, the field maxima.
// For each: header {25, 1, 0x83}; PB1-8 the vendor and PB9-24 the product,
// left-aligned and zero-padded; PB25 the SDI; PB26-27 zero; and the header
// plus PB0-27 summing to 0 mod 256 (CTA-861 InfoFrame checksum).
//----------------------------------------------------------------------------
`default_nettype none

module spd_probe #(
    parameter logic  [ 63:0] VENDOR       = "hh-hdmi",
    parameter logic  [127:0] PRODUCT      = "HDMI source",
    parameter logic  [  7:0] SDI          = 8'h00,
    parameter bit            USE_DEFAULTS = 1'b0,
    parameter string         NAME         = "?"
) (
    input  wire logic       clk,
    input  wire logic       rst_n,
    input  wire logic       packet_enable,
    input  wire logic [4:0] counter,
    input  wire logic       field_end,
    output int              errors,
    output logic            seen
);
  logic [ 23:0] header;
  logic [223:0] subs;

  if (USE_DEFAULTS) begin : g_def
    hdmi_audio_src u_src (
        .clk_pix        (clk),
        .rst_n,
        .audio_l        (16'd0),
        .audio_r        (16'd0),
        .aud_rate       (2'd0),
        .aud_depth      (2'd0),
        .vic            (8'd4),
        .aud_div_max_i  (13'd1546),
        .aud_div_frac_i (8'd224),
        .packet_enable,
        .counter,
        .video_field_end(field_end),
        .header,
        .subs
    );
  end else begin : g_set
    hdmi_audio_src #(
        .SPD_VENDOR (VENDOR),
        .SPD_PRODUCT(PRODUCT),
        .SPD_SDI    (SDI)
    ) u_src (
        .clk_pix        (clk),
        .rst_n,
        .audio_l        (16'd0),
        .audio_r        (16'd0),
        .aud_rate       (2'd0),
        .aud_depth      (2'd0),
        .vic            (8'd4),
        .aud_div_max_i  (13'd1546),
        .aud_div_frac_i (8'd224),
        .packet_enable,
        .counter,
        .video_field_end(field_end),
        .header,
        .subs
    );
  end

  // The expected PB1-PB27, built independently: character i of a name is
  // byte i counted from its first non-zero byte.
  function automatic logic [7:0] ch(input logic [127:0] s, input int bytes, input int i);
    int first;
    first = bytes;  // the highest non-zero byte holds the first character
    for (int k = bytes - 1; k >= 0; k--) begin
      if (s[8*k+:8] != 8'h00) begin
        first = k;
        break;
      end
    end
    if (first == bytes || i > first) return 8'h00;
    return s[8*(first-i)+:8];
  endfunction

  logic [7:0] exp_pb[28];
  initial begin
    errors = 0;
    seen   = 1'b0;
    for (int i = 0; i < 28; i++) exp_pb[i] = 8'h00;
    for (int i = 0; i < 8; i++) exp_pb[1+i] = ch({64'd0, VENDOR}, 8, i);
    for (int i = 0; i < 16; i++) exp_pb[9+i] = ch(PRODUCT, 16, i);
    exp_pb[25] = SDI;
  end

  always @(posedge clk) begin
    if (rst_n && !seen && header[7:0] == 8'h83) begin
      logic [7:0] sum;
      seen = 1'b1;
      if (header !== {8'd25, 8'd1, 8'h83}) begin
        $display("tb_spd: FAIL %s: header %h", NAME, header);
        errors++;
      end
      sum = header[7:0] + header[15:8] + header[23:16];
      for (int i = 0; i < 28; i++) begin
        sum += subs[8*i+:8];
        if (i > 0 && subs[8*i+:8] !== exp_pb[i]) begin
          $display("tb_spd: FAIL %s: PB%0d = %h, expected %h", NAME, i, subs[8*i+:8], exp_pb[i]);
          errors++;
        end
      end
      if (sum !== 8'h00) begin
        $display("tb_spd: FAIL %s: checksum leaves %h", NAME, sum);
        errors++;
      end
    end
  end
endmodule

module tb_spd;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;
  logic [4:0] counter = 5'd0;
  logic packet_enable, field_end = 1'b0;
  always @(posedge clk) counter <= counter + 5'd1;
  assign packet_enable = (counter == 5'd0);

  int e0, e1, e2;
  logic s0, s1, s2;

  spd_probe #(
      .USE_DEFAULTS(1'b1),
      .NAME        ("defaults")
  ) u_def (
      .clk,
      .rst_n,
      .packet_enable,
      .counter,
      .field_end,
      .errors(e0),
      .seen  (s0)
  );
  spd_probe #(
      .VENDOR ("Atari"),
      .PRODUCT("Atari 2600"),
      .SDI    (8'h08),
      .NAME   ("console")
  ) u_atari (
      .clk,
      .rst_n,
      .packet_enable,
      .counter,
      .field_end,
      .errors(e1),
      .seen  (s1)
  );
  spd_probe #(
      .VENDOR ("ABCDEFGH"),
      .PRODUCT("0123456789abcdef"),
      .SDI    (8'h09),
      .NAME   ("full fields")
  ) u_full (
      .clk,
      .rst_n,
      .packet_enable,
      .counter,
      .field_end,
      .errors(e2),
      .seen  (s2)
  );

  // The console's SPD body, assembled by hand (PB1-5 vendor, PB9-18 product, PB25 SDI).
  logic [7:0] want[28];
  initial begin
    for (int i = 0; i < 28; i++) want[i] = 8'h00;
    {want[1], want[2], want[3], want[4], want[5]} = "Atari";
    {want[9], want[10], want[11], want[12], want[13], want[14], want[15],
     want[16], want[17], want[18]} = "Atari 2600";
    want[25] = 8'h08;
  end
  int e_want = 0;
  always @(posedge clk) begin
    if (rst_n && u_atari.header[7:0] == 8'h83) begin
      for (int i = 1; i < 28; i++)
      if (u_atari.subs[8*i+:8] !== want[i]) begin
        $display("tb_spd: FAIL console PB%0d = %h, expected %h", i, u_atari.subs[8*i+:8], want[i]);
        e_want++;
      end
    end
  end

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);
    field_end = 1'b1;
    @(posedge clk);
    field_end = 1'b0;
    // ACR, audio and the other InfoFrames go first; SPD follows within a few
    // dozen 32-pixel slots.
    repeat (32 * 200) @(posedge clk);
    if (s0 && s1 && s2 && e0 + e1 + e2 + e_want == 0)
      $display(
          "tb_spd: PASS (SPD InfoFrame from the parameters: defaults, a console's hand-assembled bytes, full-length fields; checksum clean)"
      );
    else
      $display(
          "tb_spd: FAIL (seen %b%b%b, errors %0d/%0d/%0d, want %0d)", s0, s1, s2, e0, e1, e2, e_want
      );
    $finish;
  end
endmodule

`default_nettype wire

// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_avi.sv -- the AVI InfoFrame: its picture aspect follows the VIC, and its
// Active Format Description comes from the AVI_AFD_VALID / AVI_AFD parameters
// of hdmi_audio_src.
//
// Instances, each run until it emits its AVI packet (type 0x82):
//   * the defaults: no active-format information (PB1 A0 = 0), R = 1000
//     (same as the coded frame), so a sink shows the whole 16:9 frame;
//   * AFD valid with 1001 (4:3 centered, a pillarboxed 4:3 console picture):
//     PB1 0x10, PB2 0x29;
//   * AFD valid with 1010 (16:9 centered): PB1 0x10, PB2 0x2A;
//   * picture aspect (PB2 M1-M0) from the VIC (CTA-861 Table 3): 4:3 (01)
//     for VIC 1, 2, 17 and 58; 16:9 (10) for VIC 3, 16, 19, 34, 62 and 95;
//     no data (00) for VIC 0 (not a CTA format) and for the 64:27 and
//     256:135 formats, VIC 65 and 98, which the field cannot express.
// For each: header {13, 2, 0x82}; PB3 0x88 (IT content, full-range RGB);
// PB4 the VIC input; PB5-27 zero; the header plus PB0-27 summing to 0.
//----------------------------------------------------------------------------
`default_nettype none

module avi_probe #(
    parameter bit          USE_DEFAULTS = 1'b0,
    parameter bit          AFD_VALID    = 1'b0,
    parameter logic  [3:0] AFD          = 4'b1000,
    parameter logic  [7:0] EXP_PB1      = 8'h00,
    parameter logic  [7:0] EXP_PB2      = 8'h28,
    parameter logic  [7:0] VIC          = 8'd4,
    parameter string       NAME         = "?"
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
        .vic            (VIC),
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
        .AVI_AFD_VALID(AFD_VALID),
        .AVI_AFD      (AFD)
    ) u_src (
        .clk_pix        (clk),
        .rst_n,
        .audio_l        (16'd0),
        .audio_r        (16'd0),
        .aud_rate       (2'd0),
        .aud_depth      (2'd0),
        .vic            (VIC),
        .aud_div_max_i  (13'd1546),
        .aud_div_frac_i (8'd224),
        .packet_enable,
        .counter,
        .video_field_end(field_end),
        .header,
        .subs
    );
  end

  initial begin
    errors = 0;
    seen   = 1'b0;
  end

  always @(posedge clk) begin
    if (rst_n && !seen && header[7:0] == 8'h82) begin
      logic [7:0] sum, want;
      seen = 1'b1;
      if (header !== {8'd13, 8'd2, 8'h82}) begin
        $display("tb_avi: FAIL %s: header %h", NAME, header);
        errors++;
      end
      sum = header[7:0] + header[15:8] + header[23:16];
      for (int i = 0; i < 28; i++) begin
        sum += subs[8*i+:8];
        case (i)
          0:       want = subs[7:0];  // the checksum, checked by the sum
          1:       want = EXP_PB1;
          2:       want = EXP_PB2;
          3:       want = 8'h88;
          4:       want = VIC;
          default: want = 8'h00;
        endcase
        if (subs[8*i+:8] !== want) begin
          $display("tb_avi: FAIL %s: PB%0d = %h, expected %h", NAME, i, subs[8*i+:8], want);
          errors++;
        end
      end
      if (sum !== 8'h00) begin
        $display("tb_avi: FAIL %s: checksum leaves %h", NAME, sum);
        errors++;
      end
    end
  end
endmodule

module tb_avi;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;
  logic [4:0] counter = 5'd0;
  logic packet_enable, field_end = 1'b0;
  always @(posedge clk) counter <= counter + 5'd1;
  assign packet_enable = (counter == 5'd0);

  int e0, e1, e2;
  logic s0, s1, s2;
  localparam int NV = 12;
  // case k is byte NV-1-k of each list (the first listed is k = 0)
  localparam logic [8*NV-1:0] VICS = {
    8'd1, 8'd2, 8'd17, 8'd58, 8'd3, 8'd16, 8'd19, 8'd34, 8'd62, 8'd95, 8'd0, 8'd65
  };
  localparam logic [8*NV-1:0] PB2S = {
    8'h18, 8'h18, 8'h18, 8'h18, 8'h28, 8'h28, 8'h28, 8'h28, 8'h28, 8'h28, 8'h08, 8'h08
  };
  int   ev[NV+1];
  logic sv[NV+1];
  for (genvar k = 0; k < NV; k++) begin : g_vic
    avi_probe #(
        .USE_DEFAULTS(1'b1),
        .VIC         (VICS[8*(NV-1-k)+:8]),
        .EXP_PB1     (8'h00),
        .EXP_PB2     (PB2S[8*(NV-1-k)+:8]),
        .NAME        ("VIC")
    ) u_vic (
        .clk,
        .rst_n,
        .packet_enable,
        .counter,
        .field_end,
        .errors(ev[k]),
        .seen  (sv[k])
    );
  end
  avi_probe #(
      .USE_DEFAULTS(1'b1),
      .VIC         (8'd98),
      .EXP_PB1     (8'h00),
      .EXP_PB2     (8'h08),
      .NAME        ("VIC 98")
  ) u_vic98 (
      .clk,
      .rst_n,
      .packet_enable,
      .counter,
      .field_end,
      .errors(ev[NV]),
      .seen  (sv[NV])
  );

  avi_probe #(
      .USE_DEFAULTS(1'b1),
      .EXP_PB1     (8'h00),
      .EXP_PB2     (8'h28),
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
  avi_probe #(
      .AFD_VALID(1'b1),
      .AFD      (4'b1001),
      .EXP_PB1  (8'h10),
      .EXP_PB2  (8'h29),
      .NAME     ("4:3 center")
  ) u_4x3 (
      .clk,
      .rst_n,
      .packet_enable,
      .counter,
      .field_end,
      .errors(e1),
      .seen  (s1)
  );
  avi_probe #(
      .AFD_VALID(1'b1),
      .AFD      (4'b1010),
      .EXP_PB1  (8'h10),
      .EXP_PB2  (8'h2A),
      .NAME     ("16:9 center")
  ) u_16x9 (
      .clk,
      .rst_n,
      .packet_enable,
      .counter,
      .field_end,
      .errors(e2),
      .seen  (s2)
  );

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (3) @(posedge clk);
    field_end = 1'b1;
    @(posedge clk);
    field_end = 1'b0;
    repeat (32 * 200) @(posedge clk);
    begin
      int ve;
      bit vs;
      ve = 0;
      vs = 1'b1;
      for (int k = 0; k <= NV; k++) begin
        ve += ev[k];
        vs &= sv[k];
        if (ev[k] != 0) $display("tb_avi: FAIL VIC case %0d wrong", k);
      end
      if (s0 && s1 && s2 && vs && e0 + e1 + e2 + ve == 0)
        $display(
            "tb_avi: PASS (picture aspect from the VIC: 4:3, 16:9, none for VIC 0 and 64:27/256:135; active format from the parameters: none by default, 4:3 center, 16:9; checksum clean)"
        );
      else
        $display(
            "tb_avi: FAIL (seen %b%b%b%b, errors %0d/%0d/%0d/%0d)", s0, s1, s2, vs, e0, e1, e2, ve
        );
    end
    $finish;
  end
endmodule

`default_nettype wire

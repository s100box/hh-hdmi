// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_sync_timing.sv -- where HSYNC and VSYNC land against the video.
//
// Drives hdmi_encoder the way a board top does -- a raster whose cx leads the
// pixel data by one clock -- and decodes TMDS channel 0 the way a sink does:
// control tokens carry {VSYNC, HSYNC} in blanking, TERC4 symbols carry them
// in bits [1:0] inside data islands, and anything else is a video pixel. It
// then measures, in pixels on the wire:
//
//   * HSYNC asserts exactly h_sync_off + 1 pixels after the last active pixel
//     of the line (i.e. at pixel h_active + h_sync_off), and stays asserted
//     for h_sync_wid pixels;
//   * VSYNC asserts exactly v_sync_off * h_total + h_sync_off + 1 pixels after
//     the last active pixel of the frame (on the HSYNC edge of line v_active +
//     v_sync_off - 1, CEA-861's convention), for v_sync_wid lines.
//
// Four encoders: 1280x720p60 (positive syncs, sync edges outside the data
// island) and 640x480p60 (negative syncs, the HSYNC edge inside the island,
// so the island-carried sync bits are what is measured), each with
// DI_PIPE = 0 and 1. The raster starts three lines before the end of the
// active area so the vertical blanking arrives in a few thousand clocks.
//
// The one symbol that cannot be classified alone is 1011001100: it is both
// the channel-0 video guard band and the TERC4 code of nibble 1000 -- and
// nibble 1000 is exactly what a data island carries on the pixel where a
// negative HSYNC and VSYNC assert together. So the decoder looks two symbols
// ahead: a video guard band is always followed at once by video, so the
// symbol is a guard (no sync information) only if a video symbol follows
// within two, and TERC4 nibble 1000 otherwise.
//----------------------------------------------------------------------------
`default_nettype none

module sync_probe #(
    parameter bit           DI_PIPE = 1'b1,
    parameter logic  [11:0] HA      = 12'd1280,
                            VA      = 12'd720,
                            HT      = 12'd1650,
                            VT      = 12'd750,
    parameter logic  [11:0] HSO     = 12'd110,
                            HSW     = 12'd40,
                            VSO     = 12'd5,
                            VSW     = 12'd5,
    parameter bit           HPOL    = 1'b1,
                            VPOL    = 1'b1,
    parameter logic  [ 4:0] NPACK   = 5'd1,
    parameter string        NAME    = "720p"
) (
    input  wire logic clk,
    input  wire logic rst_n,
    output int        errors,
    output int        hs_checked,
    output logic      vs_checked
);
  logic [11:0] cx, cy;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cx <= 12'd0;
      cy <= VA - 12'd3;
    end else if (cx == HT - 1) begin
      cx <= 12'd0;
      cy <= (cy == VT - 1) ? 12'd0 : cy + 12'd1;
    end else cx <= cx + 12'd1;
  end
  // Pixel data lags cx by one clock; all black, so a video symbol is one of
  // the two channel-0 codes for 0x00 and never a control or TERC4 symbol.
  logic [9:0] tmds_r, tmds_g, tmds_b;
  hdmi_encoder #(
      .DI_PIPE(DI_PIPE)
  ) u_enc (
      .clk_pix     (clk),
      .rst_n       (rst_n),
      .h_active    (HA),
      .v_active    (VA),
      .h_total     (HT),
      .v_total     (VT),
      .h_sync_off  (HSO),
      .h_sync_wid  (HSW),
      .v_sync_off  (VSO),
      .v_sync_wid  (VSW),
      .h_pol       (HPOL),
      .v_pol       (VPOL),
      .di_npackets (NPACK),
      .vic         (8'd4),
      .aud_div_max (13'd1546),
      .aud_div_frac(8'd224),
      .cx          (cx),
      .cy          (cy),
      .rgb_r       (8'h00),
      .rgb_g       (8'h00),
      .rgb_b       (8'h00),
      .audio_l     (16'h0000),
      .audio_r     (16'h0000),
      .aud_rate    (2'd0),
      .aud_depth   (2'd0),
      .tmds_r      (tmds_r),
      .tmds_g      (tmds_g),
      .tmds_b      (tmds_b)
  );

  // ---- channel-0 decode ---------------------------------------------------
  function automatic int terc4(input logic [9:0] s);
    case (s)
      10'b1010011100: return 0;
      10'b1001100011: return 1;
      10'b1011100100: return 2;
      10'b1011100010: return 3;
      10'b0101110001: return 4;
      10'b0100011110: return 5;
      10'b0110001110: return 6;
      10'b0100111100: return 7;
      10'b1011001100: return 8;
      10'b0100111001: return 9;
      10'b0110011100: return 10;
      10'b1011000110: return 11;
      10'b1010001110: return 12;
      10'b1001110001: return 13;
      10'b0101100011: return 14;
      10'b1011000011: return 15;
      default: return -1;
    endcase
  endfunction

  // kind: 0 video, 1 control/island (sync known), 2 no information
  task automatic classify(input logic [9:0] s, output int kind, output logic [1:0] vh);
    int t;
    kind = 1;
    vh   = 2'b00;
    case (s)
      10'b1101010100: vh = 2'b00;
      10'b0010101011: vh = 2'b01;
      10'b0101010100: vh = 2'b10;
      10'b1010101011: vh = 2'b11;
      10'b1011001100: kind = 2;
      default: begin
        t = terc4(s);
        if (t >= 0) vh = t[1:0];
        else kind = 0;
      end
    endcase
  endtask

  // ---- measurement ------------------------------------------------------------
  longint p = 0;  // symbols seen since reset (plus pipeline fill)
  longint last_video = -1;  // index of the most recent video symbol
  longint hs_rise = -1, vs_rise = -1;
  logic hs = 1'b0, vs = 1'b0;  // asserted, in the sink's view
  logic seen_video = 1'b0;
  int kind;
  logic [1:0] vh;
  logic hs_now, vs_now;

  initial begin
    errors     = 0;
    hs_checked = 0;
    vs_checked = 1'b0;
  end

  // Two-symbol lookahead: the symbol measured is the one from two clocks ago.
  logic [9:0] s1, s2;
  int k0, k1;
  logic [1:0] vh0;
  always @(posedge clk) begin
    if (rst_n) begin
      s2 <= s1;
      s1 <= tmds_b;
      p++;
      classify(s2, kind, vh);
      classify(s1, k1, vh0);
      classify(tmds_b, k0, vh0);
      if (kind == 2 && k1 != 0 && k0 != 0) begin
        kind = 1;  // not a guard: TERC4 nibble 1000
        vh   = 2'b00;
      end
      // The first few symbols are the delay line and the encoder's pipeline
      // filling from reset (unknown values, then reset-state control
      // symbols); nothing is measured until real video has gone by.
      if (p <= 16) begin
      end else if (kind == 0) begin
        last_video = p;
        seen_video = 1'b1;
      end else if (kind == 1 && seen_video) begin
        hs_now = (vh[0] == HPOL);
        vs_now = (vh[1] == VPOL);
        if (hs_now && !hs) begin
          hs_rise = p;
          // only lines that carried video have a last-active reference
          if (p - last_video < HT) begin
            if (p - last_video != HSO + 1) begin
              $display(
                  "tb_sync_timing: FAIL %s DI_PIPE=%0d: HSYNC asserts %0d pixels after the last active pixel, expected %0d",
                  NAME, DI_PIPE, p - last_video, HSO + 1);
              errors++;
            end
            hs_checked++;
          end
        end
        if (!hs_now && hs && hs_rise >= 0 && p - hs_rise != HSW) begin
          $display("tb_sync_timing: FAIL %s DI_PIPE=%0d: HSYNC width %0d, expected %0d", NAME,
                   DI_PIPE, p - hs_rise, HSW);
          errors++;
        end
        if (vs_now && !vs) begin
          vs_rise = p;
          if (p - last_video != VSO * HT + HSO + 1) begin
            $display(
                "tb_sync_timing: FAIL %s DI_PIPE=%0d: VSYNC asserts %0d pixels after the frame's last active pixel, expected %0d",
                NAME, DI_PIPE, p - last_video, VSO * HT + HSO + 1);
            errors++;
          end
        end
        if (!vs_now && vs && vs_rise >= 0) begin
          if (p - vs_rise != VSW * HT) begin
            $display("tb_sync_timing: FAIL %s DI_PIPE=%0d: VSYNC lasts %0d pixels, expected %0d",
                     NAME, DI_PIPE, p - vs_rise, VSW * HT);
            errors++;
          end
          vs_checked = 1'b1;
        end
        hs = hs_now;
        vs = vs_now;
      end
    end
  end
endmodule

module tb_sync_timing;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;

  int e0, e1, e2, e3, h0, h1, h2, h3;
  logic v0, v1, v2, v3;

  sync_probe #(
      .DI_PIPE(1'b1),
      .NAME   ("720p")
  ) u_720_p1 (
      .clk,
      .rst_n,
      .errors    (e0),
      .hs_checked(h0),
      .vs_checked(v0)
  );
  sync_probe #(
      .DI_PIPE(1'b0),
      .NAME   ("720p")
  ) u_720_p0 (
      .clk,
      .rst_n,
      .errors    (e1),
      .hs_checked(h1),
      .vs_checked(v1)
  );
  sync_probe #(
      .DI_PIPE(1'b1),
      .HA     (12'd640),
      .VA     (12'd480),
      .HT     (12'd800),
      .VT     (12'd525),
      .HSO    (12'd16),
      .HSW    (12'd96),
      .VSO    (12'd10),
      .VSW    (12'd2),
      .HPOL   (1'b0),
      .VPOL   (1'b0),
      .NPACK  (5'd2),
      .NAME   ("640x480")
  ) u_480_p1 (
      .clk,
      .rst_n,
      .errors    (e2),
      .hs_checked(h2),
      .vs_checked(v2)
  );
  sync_probe #(
      .DI_PIPE(1'b0),
      .HA     (12'd640),
      .VA     (12'd480),
      .HT     (12'd800),
      .VT     (12'd525),
      .HSO    (12'd16),
      .HSW    (12'd96),
      .VSO    (12'd10),
      .VSW    (12'd2),
      .HPOL   (1'b0),
      .VPOL   (1'b0),
      .NPACK  (5'd2),
      .NAME   ("640x480")
  ) u_480_p0 (
      .clk,
      .rst_n,
      .errors    (e3),
      .hs_checked(h3),
      .vs_checked(v3)
  );

  initial begin
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    // 720p: 3 active lines + 5 front-porch lines + 5 sync lines + margin
    repeat (15 * 1650) @(posedge clk);
    if (e0 + e1 + e2 + e3 == 0 && h0 >= 3 && h1 >= 3 && h2 >= 3 && h3 >= 3 && v0 && v1 && v2 && v3)
      $display(
          "tb_sync_timing: PASS (HSYNC and VSYNC exact against the video: 720p +/+ and 640x480 -/-, DI_PIPE 0 and 1; %0d+%0d+%0d+%0d line edges)",
          h0,
          h1,
          h2,
          h3
      );
    else
      $display(
          "tb_sync_timing: FAIL (errors %0d/%0d/%0d/%0d, line edges %0d/%0d/%0d/%0d, VSYNC seen %b%b%b%b)",
          e0,
          e1,
          e2,
          e3,
          h0,
          h1,
          h2,
          h3,
          v0,
          v1,
          v2,
          v3
      );
    $finish;
  end
endmodule

`default_nettype wire

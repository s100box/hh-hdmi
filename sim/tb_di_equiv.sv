// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_di_equiv.sv -- differential equivalence bench for the DI_PIPE pipeline.
//
// Drives two hdmi_encoder instances with IDENTICAL stimulus -- a reference with
// DI_PIPE=0 (the unpipelined data-island path) and a DUT with DI_PIPE=1
// (the pipelined path) -- over a compact raster with audio active, and checks that
// their three TMDS lanes are bit-identical. It sweeps a small capture latency L and
// reports, per L, how many pixels mismatch; DI_PIPE is behavior-preserving iff some
// L gives 0 mismatches (L is the uniform pixel latency the pipeline adds). PASS
// requires L == 1, the uniform one-pixel latency DI_PIPE adds.
//----------------------------------------------------------------------------
`default_nettype none

module tb_di_equiv;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;

  // Compact raster that still contains a full data-island region:
  //   di_start = h_active+14 = 78, di_end = 78 + 4*32 = 206 < h_total.
  localparam [11:0] H_ACTIVE = 12'd64, V_ACTIVE = 12'd4;
  localparam [11:0] H_TOTAL = 12'd280, V_TOTAL = 12'd8;
  localparam [4:0] NPACK = 5'd4;

  logic [11:0] cx = 0, cy = 0;
  logic [7:0] rgb_r, rgb_g, rgb_b;
  logic [15:0] audio_l = 16'h1234, audio_r = 16'hABCD;

  // Free-running raster scan.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cx <= 12'd0;
      cy <= 12'd0;
    end else if (cx == H_TOTAL - 1) begin
      cx <= 12'd0;
      cy <= (cy == V_TOTAL - 1) ? 12'd0 : cy + 12'd1;
    end else cx <= cx + 12'd1;
  end
  // Deterministic pixel data + slowly varying audio samples.
  always_comb begin
    rgb_r = cx[7:0] ^ cy[7:0];
    rgb_g = cx[7:0] + cy[7:0];
    rgb_b = ~cx[7:0];
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      audio_l <= 16'h1234;
      audio_r <= 16'hABCD;
    end else begin
      audio_l <= audio_l + 16'd7;
      audio_r <= audio_r - 16'd3;
    end
  end

  logic [9:0] r0, g0, b0, r1, g1, b1;

  hdmi_encoder #(
      .DI_PIPE(1'b0)
  ) u_ref (
      .clk_pix     (clk),
      .rst_n       (rst_n),
      .h_active    (H_ACTIVE),
      .v_active    (V_ACTIVE),
      .h_total     (H_TOTAL),
      .v_total     (V_TOTAL),
      .h_sync_off  (12'd8),
      .h_sync_wid  (12'd8),
      .v_sync_off  (12'd1),
      .v_sync_wid  (12'd1),
      .h_pol       (1'b1),
      .v_pol       (1'b1),
      .di_npackets (NPACK),
      .vic         (8'd4),
      .aud_div_max (13'd40),
      .aud_div_frac(8'd0),
      .cx          (cx),
      .cy          (cy),
      .rgb_r       (rgb_r),
      .rgb_g       (rgb_g),
      .rgb_b       (rgb_b),
      .audio_l     (audio_l),
      .audio_r     (audio_r),
      .aud_rate    (2'd0),
      .aud_depth   (2'd0),
      .tmds_r      (r0),
      .tmds_g      (g0),
      .tmds_b      (b0)
  );

  hdmi_encoder #(
      .DI_PIPE(1'b1)
  ) u_dut (
      .clk_pix     (clk),
      .rst_n       (rst_n),
      .h_active    (H_ACTIVE),
      .v_active    (V_ACTIVE),
      .h_total     (H_TOTAL),
      .v_total     (V_TOTAL),
      .h_sync_off  (12'd8),
      .h_sync_wid  (12'd8),
      .v_sync_off  (12'd1),
      .v_sync_wid  (12'd1),
      .h_pol       (1'b1),
      .v_pol       (1'b1),
      .di_npackets (NPACK),
      .vic         (8'd4),
      .aud_div_max (13'd40),
      .aud_div_frac(8'd0),
      .cx          (cx),
      .cy          (cy),
      .rgb_r       (rgb_r),
      .rgb_g       (rgb_g),
      .rgb_b       (rgb_b),
      .audio_l     (audio_l),
      .audio_r     (audio_r),
      .aud_rate    (2'd0),
      .aud_depth   (2'd0),
      .tmds_r      (r1),
      .tmds_g      (g1),
      .tmds_b      (b1)
  );

  // Compare on negedge (all posedge NBAs settled). ref history is kept with
  // blocking assignments so hist[L] is exactly ref[t-L]; L=0 is the same cycle.
  localparam int MAXL = 4;
  logic   [29:0] hist       [MAXL+1];  // hist[L] = ref value L cycles ago
  integer        mism       [MAXL+1];
  integer        nchk = 0;
  integer        settle = 0;
  integer first_bad_l0_cx = -1, first_bad_l0_cy = -1;
  integer i, L;

  initial begin
    for (i = 0; i <= MAXL; i = i + 1) begin
      mism[i] = 0;
      hist[i] = 30'bx;
    end
    repeat (8) @(posedge clk);
    rst_n = 1;
  end

  always @(negedge clk) begin
    if (rst_n) begin
      // shift history, then load this cycle's ref into hist[0] (so hist[L]=ref[t-L]).
      for (i = MAXL; i > 0; i = i - 1) hist[i] = hist[i-1];
      hist[0] = {r0, g0, b0};
      settle  = settle + 1;
      if (settle > 40) begin  // skip the initial reset/fill transient
        nchk = nchk + 1;
        for (L = 0; L <= MAXL; L = L + 1) begin
          if ({r1, g1, b1} !== hist[L]) begin
            mism[L] = mism[L] + 1;
            if (L == 0 && first_bad_l0_cx < 0) begin
              first_bad_l0_cx = cx;
              first_bad_l0_cy = cy;
            end
          end
        end
      end
    end
  end

  initial begin
    #200000;  // ~20k pixels -> many full DI regions + audio packets
    $display("tb_di_equiv: checked %0d pixels", nchk);
    for (i = 0; i <= MAXL; i = i + 1) $display("  latency L=%0d : %0d mismatches", i, mism[i]);
    // DI_PIPE is a uniform one-pixel pipeline, so the DUT should equal the reference
    // delayed by exactly one pixel (L=1) with zero mismatches.
    if (mism[1] == 0)
      $display("tb_di_equiv: PASS (DI_PIPE bit-identical to the reference, +1 pixel latency)");
    else begin
      $display(
          "tb_di_equiv: FAIL -- no clean latency (L=1 has %0d mismatches; first L=0 diff near cx=%0d cy=%0d)",
          mism[1], first_bad_l0_cx, first_bad_l0_cy);
      $fatal(1);
    end
    $finish;
  end
endmodule

`default_nettype wire

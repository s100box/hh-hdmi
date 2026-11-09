// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_encoder_modes.sv -- one hdmi_encoder reconfigured at run time.
//
// A board with a mode table drives the timing inputs from registers and resets
// the encoder across a mode switch. This bench does the same to one instance
// (DI_PIPE = 1), stepping through five CEA/DMT modes (640x480, 720x480, 720p,
// 1080p, 1680x1050) and five synthetic ones that together set and clear every
// bit of every timing, VIC and audio input: a wide mode (h_active 2095, odd
// h_total, VIC 232), one with an h_sync_off of 3969 and 20 packets per island,
// one with an h_sync_wid of 4001, and two 4095-line modes with a v_sync_off of
// 4080 and a v_sync_wid of 4088. The synthetic h_active values (18, 4) and the
// 20 packets also set and clear every bit of the encoder's registered sums
// (di_start, di_end, ha_m1 and the rest). Each mode runs from two lines before the end of
// the active area into line 1 of the next frame, visiting the lines around the
// end of the active area, the VSYNC edges and the frame wrap.
//
// Every output pixel of all three lanes is checked against a model of the
// period the sink must see at that raster position:
//   * video: the symbol decodes (DVI 1.0) to the pixel driven;
//   * video guard: the two pixels before each active line;
//   * control: lane 0 carries {VSYNC, HSYNC}, lanes 1 and 2 the preamble
//     (CTL0 for both preambles, CTL2 for the data island's);
//   * data-island guard and body: lane 0 is TERC4 {1, 1, VSYNC, HSYNC} on the
//     guards and {D3, header bit, VSYNC, HSYNC} in the body, D3 low only on the
//     island's first pixel; lanes 1 and 2 are TERC4; each 32-pixel packet's
//     header and four subpackets pass their BCH(8) check and its type is one
//     the source sends.
// HSYNC is asserted for h_sync_wid pixels from h_active + h_sync_off; VSYNC
// from that HSYNC edge on line v_active + v_sync_off - 1 to the one v_sync_wid
// lines later; both at the mode's polarity.
//
// Built with HDMI_DVI_ONLY, the same raster must carry video and control only,
// with no guards, preambles or islands.
//----------------------------------------------------------------------------
`default_nettype none

module tb_encoder_modes;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;

  // ── Mode table ────────────────────────────────────────────────────────────
  localparam int NM = 11;
  // One row per mode: h_active, v_active, h_total, v_total, h_sync_off,
  // h_sync_wid, v_sync_off, v_sync_wid, packets, VIC, audio divider (integer,
  // /256), rate, depth, h_pol, v_pol.
  localparam int HA = 0, VA = 1, HT = 2, VT = 3, HSO = 4, HSW = 5, VSO = 6, VSW = 7;
  localparam int NPK = 8, VIC = 9, ADM = 10, ADF = 11, RATE = 12, DEPTH = 13, HP = 14, VP = 15;
  int mt[NM][16];
  string mname[NM];
  task automatic row(input int m, input string name, input int v0, input int v1, input int v2,
                     input int v3, input int v4, input int v5, input int v6, input int v7,
                     input int v8, input int v9, input int v10, input int v11, input int v12,
                     input int v13, input int v14, input int v15);
    mname[m]  = name;
    mt[m][0]  = v0;
    mt[m][1]  = v1;
    mt[m][2]  = v2;
    mt[m][3]  = v3;
    mt[m][4]  = v4;
    mt[m][5]  = v5;
    mt[m][6]  = v6;
    mt[m][7]  = v7;
    mt[m][8]  = v8;
    mt[m][9]  = v9;
    mt[m][10] = v10;
    mt[m][11] = v11;
    mt[m][12] = v12;
    mt[m][13] = v13;
    mt[m][14] = v14;
    mt[m][15] = v15;
  endtask
  initial begin
    row(0, "640x480", 640, 480, 800, 525, 16, 96, 10, 2, 4, 1, 525, 0, 0, 0, 0, 0);
    row(1, "720x480", 720, 480, 858, 525, 16, 62, 9, 6, 3, 3, 612, 61, 1, 1, 0, 0);
    row(2, "1280x720", 1280, 720, 1650, 750, 110, 40, 5, 5, 10, 4, 1546, 224, 0, 2, 1, 1);
    row(3, "1920x1080", 1920, 1080, 2200, 1125, 88, 44, 4, 5, 7, 16, 4640, 154, 2, 0, 1, 1);
    row(4, "1680x1050", 1680, 1050, 1840, 1080, 48, 32, 3, 6, 4, 0, 2479, 43, 0, 1, 1, 0);
    row(5, "wide", 2095, 2053, 2157, 2057, 8, 8, 1, 1, 1, 232, 496, 17, 1, 2, 1, 0);
    row(6, "far hsync", 16, 4, 4095, 12, 3969, 8, 1, 1, 20, 4, 4640, 200, 2, 1, 0, 1);
    row(7, "wide hsync", 18, 4, 4095, 12, 8, 4001, 1, 1, 1, 0, 800, 0, 0, 0, 1, 1);
    row(8, "far vsync", 4, 4, 74, 4095, 4, 4, 4080, 2, 1, 2, 300, 128, 1, 2, 0, 0);
    row(9, "wide vsync", 16, 4, 74, 4095, 4, 4, 1, 4088, 1, 97, 41, 255, 0, 1, 1, 0);
    row(10, "640x480", 640, 480, 800, 525, 16, 96, 10, 2, 4, 1, 525, 0, 0, 0, 0, 0);
  end

  logic [11:0] ha, va, ht, vt, hso, hsw, vso, vsw;
  logic [4:0] npk;
  logic [7:0] vic, adf;
  logic [12:0] adm;
  logic [1:0] rate, depth;
  logic hp, vp;

  // ── Raster: cx leads the pixel data by one clock ────────────────────────────
  // Every output depends on the raster position alone, so the raster visits only
  // the lines where something happens and steps over the rest at a line
  // boundary: the last two active lines (a video guard, then none) and the first
  // blank one, the lines where VSYNC rises and falls (mid-line, at the HSYNC
  // edge) and the line after each, and the frame wrap (the guard before line 0).
  // A 4095-line mode then costs a few lines.
  function automatic logic wanted(input int y);
    int a, b, c;
    a = int'(va);
    b = a + int'(vso);
    c = b + int'(vsw);
    return (y >= a - 2 && y <= a) || (y >= b - 1 && y <= b) || (y >= c - 1 && y <= c) ||
        (y == int'(vt) - 1) || (y <= 1);
  endfunction
  function automatic logic [11:0] next_line(input logic [11:0] y);
    int n;
    n = (int'(y) + 1) % int'(vt);
    while (!wanted(n)) n = (n + 1) % int'(vt);
    return 12'(n);
  endfunction
  logic [11:0] cx, cy;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cx <= 12'd0;
      cy <= va - 12'd2;
    end else if (cx == ht - 1) begin
      cx <= 12'd0;
      cy <= next_line(cy);
    end else cx <= cx + 12'd1;
  end
  function automatic logic [23:0] pixel(input logic [11:0] x, input logic [11:0] y);
    logic [7:0] r, g, b;
    r = 8'(x * 5 + y * 3);
    g = x[7:0] ^ {y[3:0], y[7:4]};
    b = ~8'(x[11:4] + x[3:0] + y[7:0]);
    return {r, g, b};
  endfunction
  logic [7:0] rgb_r, rgb_g, rgb_b;
  always_ff @(posedge clk) {rgb_r, rgb_g, rgb_b} <= pixel(cx, cy);
  logic [15:0] audio_l, audio_r;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      audio_l <= 16'h1234;
      audio_r <= 16'hABCD;
    end else begin
      audio_l <= audio_l + 16'd7;
      audio_r <= audio_r - 16'd3;
    end
  end

  logic [9:0] tmds_r, tmds_g, tmds_b;
  hdmi_encoder #(
      .DI_PIPE(1'b1)
  ) dut (
      .clk_pix     (clk),
      .rst_n       (rst_n),
      .h_active    (ha),
      .v_active    (va),
      .h_total     (ht),
      .v_total     (vt),
      .h_sync_off  (hso),
      .h_sync_wid  (hsw),
      .v_sync_off  (vso),
      .v_sync_wid  (vsw),
      .h_pol       (hp),
      .v_pol       (vp),
      .di_npackets (npk),
      .vic         (vic),
      .aud_div_max (adm),
      .aud_div_frac(adf),
      .cx          (cx),
      .cy          (cy),
      .rgb_r       (rgb_r),
      .rgb_g       (rgb_g),
      .rgb_b       (rgb_b),
      .audio_l     (audio_l),
      .audio_r     (audio_r),
      .aud_rate    (rate),
      .aud_depth   (depth),
      .tmds_r      (tmds_r),
      .tmds_g      (tmds_g),
      .tmds_b      (tmds_b)
  );

  // ── Symbol tables and decoders ──────────────────────────────────────────────
  function automatic logic [7:0] tmds_decode(input logic [9:0] q);
    logic [7:0] dp;
    logic [7:0] d;
    dp   = q[9] ? ~q[7:0] : q[7:0];
    d[0] = dp[0];
    for (int i = 1; i < 8; i++) d[i] = q[8] ? (dp[i] ^ dp[i-1]) : ~(dp[i] ^ dp[i-1]);
    return d;
  endfunction
  function automatic logic [9:0] ctrl_code(input logic [1:0] c);
    case (c)
      2'b00:   ctrl_code = 10'b1101010100;
      2'b01:   ctrl_code = 10'b0010101011;
      2'b10:   ctrl_code = 10'b0101010100;
      default: ctrl_code = 10'b1010101011;
    endcase
  endfunction
  function automatic logic [9:0] terc4_code(input logic [3:0] n);
    case (n)
      4'h0:    terc4_code = 10'b1010011100;
      4'h1:    terc4_code = 10'b1001100011;
      4'h2:    terc4_code = 10'b1011100100;
      4'h3:    terc4_code = 10'b1011100010;
      4'h4:    terc4_code = 10'b0101110001;
      4'h5:    terc4_code = 10'b0100011110;
      4'h6:    terc4_code = 10'b0110001110;
      4'h7:    terc4_code = 10'b0100111100;
      4'h8:    terc4_code = 10'b1011001100;
      4'h9:    terc4_code = 10'b0100111001;
      4'hA:    terc4_code = 10'b0110011100;
      4'hB:    terc4_code = 10'b1011000110;
      4'hC:    terc4_code = 10'b1010001110;
      4'hD:    terc4_code = 10'b1001110001;
      4'hE:    terc4_code = 10'b0101100011;
      default: terc4_code = 10'b1011000011;
    endcase
  endfunction
  // TERC4 decode; bit 4 set = a valid TERC4 symbol.
  function automatic logic [4:0] terc4_dec(input logic [9:0] s);
    for (int n = 0; n < 16; n++) if (terc4_code(4'(n)) == s) return {1'b1, 4'(n)};
    return 5'b0;
  endfunction
  // A symbol a video period can carry: neither control nor TERC4 nor a guard.
  function automatic logic is_video_sym(input logic [9:0] s);
    for (int c = 0; c < 4; c++) if (ctrl_code(2'(c)) == s) return 1'b0;
    return 1'b1;
  endfunction
  function automatic logic [7:0] next_ecc(input logic [7:0] ecc, input logic b);
    next_ecc = (ecc >> 1) ^ ((ecc[0] ^ b) ? 8'h83 : 8'h00);
  endfunction

  localparam logic [9:0] VGUARD_02 = 10'b1011001100;  // video guard, lanes 0 and 2
  localparam logic [9:0] VGUARD_1 = 10'b0100110011;  // video guard, lane 1
  localparam logic [9:0] DGUARD_12 = 10'b0100110011;  // island guard, lanes 1 and 2

  // ── The period model ────────────────────────────────────────────────────────
  typedef enum int {
    P_CTL,
    P_VID,
    P_VG,
    P_DIG,
    P_DI
  } period_t;
  localparam int DI_PRE = 14;

  // The raster position each output pixel came from: tmds lags cx by L clocks.
  localparam int L = 4;
  logic [11:0] hx[L], hy[L];
  always @(posedge clk) begin
    for (int i = L - 1; i > 0; i--) begin
      hx[i] <= hx[i-1];
      hy[i] <= hy[i-1];
    end
    hx[0] <= cx;
    hy[0] <= cy;
  end

  int cur = 0;  // the mode running
  integer errors = 0, n_checked = 0, n_video = 0, n_pkts = 0, n_hs = 0, n_vs = 0;
  integer since = 0;  // clocks since reset released
  logic checking = 1'b0;
  logic [31:0] hdr_w;
  logic [63:0] sub_w[4];
  logic [7:0] ptype;
  task automatic err(input string what, input int x, input int y);
    errors++;
    if (errors <= 20) $display("FAIL [%s] (%0d,%0d): %s", mname[cur], x, y, what);
  endtask

  always @(posedge clk) begin
    #1;
    if (!rst_n) since = 0;
    else since++;
    if (checking && since > L) check_pixel(int'(hx[L-1]), int'(hy[L-1]));
  end

  task automatic check_pixel(input int x, input int y);
    int dis, die, hs0, p, vs_a, vs_b, k;
    logic hs_on, vs_on, hs_w, vs_w, line_active, pre_v, pre_d;
    period_t per;
    logic [23:0] px;
    logic [4:0] t0, t1, t2;
    logic [7:0] ecc;
    n_checked++;
    dis   = int'(ha) + DI_PRE;
    die   = dis + 32 * int'(npk);
    hs0   = int'(ha) + int'(hso);
    hs_on = (x >= hs0) && (x < hs0 + int'(hsw));
    p     = y * int'(ht) + x;
    vs_a  = (int'(va) + int'(vso) - 1) * int'(ht) + hs0;
    vs_b  = (int'(va) + int'(vso) + int'(vsw) - 1) * int'(ht) + hs0;
    vs_on = (p >= vs_a) && (p < vs_b);
    hs_w  = hs_on ? hp : ~hp;  // the level on the wire
    vs_w  = vs_on ? vp : ~vp;
    if (hs_on) n_hs++;
    if (vs_on) n_vs++;
    line_active = (y == int'(vt) - 1) || (y < int'(va) - 1);
`ifdef HDMI_DVI_ONLY
    per   = (x < int'(ha) && y < int'(va)) ? P_VID : P_CTL;
    pre_v = 1'b0;
    pre_d = 1'b0;
`else
    if ((x >= dis - 2 && x < dis) || (x >= die && x < die + 2)) per = P_DIG;
    else if (x >= dis && x < die) per = P_DI;
    else if (x >= int'(ht) - 2 && line_active) per = P_VG;
    else if (x < int'(ha) && y < int'(va)) per = P_VID;
    else per = P_CTL;
    pre_v = (x >= int'(ht) - 10) && (x < int'(ht) - 2) && line_active;
    pre_d = (x >= dis - 10) && (x < dis - 2);
`endif
    case (per)
      P_VID: begin
        n_video++;
        px = pixel(12'(x), 12'(y));
        if (!is_video_sym(
                tmds_b
            ) || tmds_decode(
                tmds_b
            ) !== px[7:0] || !is_video_sym(
                tmds_g
            ) || tmds_decode(
                tmds_g
            ) !== px[15:8] || !is_video_sym(
                tmds_r
            ) || tmds_decode(
                tmds_r
            ) !== px[23:16])
          err($sformatf(
              "video %h %h %h decodes to %02h %02h %02h, want %06h",
              tmds_r,
              tmds_g,
              tmds_b,
              tmds_decode(
                  tmds_r
              ),
              tmds_decode(
                  tmds_g
              ),
              tmds_decode(
                  tmds_b
              ),
              px
              ), x, y);
      end
      P_VG: begin
        if (tmds_b !== VGUARD_02 || tmds_g !== VGUARD_1 || tmds_r !== VGUARD_02)
          err($sformatf("video guard %h %h %h", tmds_r, tmds_g, tmds_b), x, y);
      end
      P_CTL: begin
        if (tmds_b !== ctrl_code(
                {vs_w, hs_w}
            ) || tmds_g !== ctrl_code(
                {1'b0, pre_v | pre_d}
            ) || tmds_r !== ctrl_code(
                {1'b0, pre_d}
            ))
          err($sformatf(
              "control %h %h %h, want sync %b%b preamble %b%b",
              tmds_r,
              tmds_g,
              tmds_b,
              vs_w,
              hs_w,
              pre_v,
              pre_d
              ), x, y);
      end
      P_DIG: begin
        if (tmds_b !== terc4_code(
                {2'b11, vs_w, hs_w}
            ) || tmds_g !== DGUARD_12 || tmds_r !== DGUARD_12)
          err($sformatf("island guard %h %h %h, want sync %b%b", tmds_r, tmds_g, tmds_b, vs_w, hs_w
              ), x, y);
      end
      default: begin  // P_DI
        t0 = terc4_dec(tmds_b);
        t1 = terc4_dec(tmds_g);
        t2 = terc4_dec(tmds_r);
        k  = (x - dis) % 32;
        if (!t0[4] || !t1[4] || !t2[4]) err("island symbol not TERC4", x, y);
        else begin
          if (t0[1:0] !== {vs_w, hs_w} || t0[3] !== (x != dis))
            err($sformatf(
                "island lane 0 nibble %b, want D3 %b sync %b%b", t0[3:0], x != dis, vs_w, hs_w), x,
                y);
          hdr_w[k] = t0[2];
          for (int i = 0; i < 4; i++) begin
            sub_w[i][2*k]   = t1[i];
            sub_w[i][2*k+1] = t2[i];
          end
          if (k == 31) begin
            n_pkts++;
            ecc = 8'd0;
            for (int t = 0; t < 24; t++) ecc = next_ecc(ecc, hdr_w[t]);
            if (hdr_w[31:24] !== ecc) err("header BCH", x, y);
            for (int i = 0; i < 4; i++) begin
              ecc = 8'd0;
              for (int t = 0; t < 56; t++) ecc = next_ecc(ecc, sub_w[i][t]);
              if (sub_w[i][63:56] !== ecc) err($sformatf("subpacket %0d BCH", i), x, y);
            end
            ptype = hdr_w[7:0];
            if (!(ptype == 8'h00 || ptype == 8'h01 || ptype == 8'h02 || ptype == 8'h03 ||
                  ptype == 8'h82 || ptype == 8'h83 || ptype == 8'h84))
              err($sformatf("packet type %02h", ptype), x, y);
          end
        end
      end
    endcase
  endtask

  // ── Run every mode ──────────────────────────────────────────────────────────
  initial begin
    int start_pkts, start_video, start_vs;
    logic wrapped;
    for (cur = 0; cur < NM; cur++) begin
      @(negedge clk);
      rst_n    = 1'b0;
      checking = 1'b0;
      ha       = 12'(mt[cur][HA]);
      va       = 12'(mt[cur][VA]);
      ht       = 12'(mt[cur][HT]);
      vt       = 12'(mt[cur][VT]);
      hso      = 12'(mt[cur][HSO]);
      hsw      = 12'(mt[cur][HSW]);
      vso      = 12'(mt[cur][VSO]);
      vsw      = 12'(mt[cur][VSW]);
      npk      = 5'(mt[cur][NPK]);
      vic      = 8'(mt[cur][VIC]);
      adm      = 13'(mt[cur][ADM]);
      adf      = 8'(mt[cur][ADF]);
      rate     = 2'(mt[cur][RATE]);
      depth    = 2'(mt[cur][DEPTH]);
      hp       = 1'(mt[cur][HP]);
      vp       = 1'(mt[cur][VP]);
      repeat (4) @(negedge clk);
      start_pkts  = n_pkts;
      start_video = n_video;
      start_vs    = n_vs;
      rst_n       = 1'b1;
      checking    = 1'b1;
      // From two lines before the end of the active area into line 1 of the
      // next frame.
      wrapped     = 1'b0;
      while (!(wrapped && cy == 12'd1)) begin
        @(negedge clk);
        if (cy == 12'd0) wrapped = 1'b1;
      end
      repeat (L + 2) @(negedge clk);
      $display("  %-10s %0dx%0d: %0d video pixels, %0d packets, VSYNC %0d pixels", mname[cur],
               mt[cur][HA], mt[cur][VA], n_video - start_video, n_pkts - start_pkts,
               n_vs - start_vs);
`ifndef HDMI_DVI_ONLY
      if (n_pkts == start_pkts) err("no data-island packets", 0, 0);
`else
      if (n_pkts != start_pkts) err("data-island packets in a DVI-only build", 0, 0);
`endif
      if (n_video == start_video) err("no video pixels", 0, 0);
      if (n_vs == start_vs) err("no VSYNC", 0, 0);
    end
    if (errors == 0) begin
      $display(
          "tb_encoder_modes: PASS (%0d modes on one encoder, %0d pixels, %0d video, %0d packets)",
          NM, n_checked, n_video, n_pkts);
      $finish;
    end else $fatal(1, "tb_encoder_modes: FAIL (%0d errors)", errors);
  end
endmodule

`default_nettype wire

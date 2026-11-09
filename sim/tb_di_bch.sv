// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_di_bch.sv -- data-island packet INTEGRITY bench (TERC4 + BCH + content).
//
// A differential bench (tb_di_equiv) cannot see content corruption that affects
// both instances identically, so this bench checks the encoder like a sink would:
// it self-synchronizes on the data-island guard bands (ch1 AND ch2 = the island
// guard symbol, preceded by the CTL01/CTL01 island preamble -- the video guard
// only matches on ch1), TERC4-decodes the island body, reassembles each 32-pixel
// packet's header + four subpackets, and verifies:
//   * the five BCH(8) ECC bytes (generator 0x83) + the island length;
//   * audio packets: the IEC-60958 subframe parity bits, AND the stimulus pair
//     invariant -- audio_l/audio_r step +7/-3 per clock, so a subframe whose two
//     samples were latched on the SAME tick t has 3*sl + 7*sr == 3*L0 + 7*R0
//     (the t terms cancel); any packet spliced from two different packets pairs
//     samples from different ticks and breaks it deterministically;
//   * audio packet headers (HDMI 1.4 Table 5-12): HB1 = 0x0F (layout 0, four
//     samples present), HB2's sample_flat nibble [3:0] clear, and the B bits in
//     HB2[7:4] marking every 192nd frame and no other;
//   * ACR packets: N == 6144 (48 kHz) in every subpacket copy;
//   * AVI InfoFrames: the InfoFrame checksum (header + body sums to 0 mod 256);
//   * channel 0's D3: 0 on the island's first pixel, 1 on every other
//     (HDMI 1.4 Figure 5-3).
//
// The content checks matter because a MID-PACKET content switch is invisible to
// the ECC: the BCH accumulator processes the same muxed bits that are serialized,
// so a chimera packet (first half of packet N, second half of packet N+1) carries
// a self-consistent ECC and only its MEANING is corrupt.
//
// Two checkers run the same encoder configuration at different h_active:
//   * ALIGNED   h_active % 32 == 0  (most modes; 1280x720, 1920x1080, 640x480)
//   * UNALIGNED h_active % 32 == 16 (the 1680x1050 class)
// The second guards the packet_enable window alignment: a packet boundary
// derived from cx's absolute low bits (cx[4:0] == 14) instead of the packet
// window start (cx[4:0] == di_start[4:0]) fires mid-window when h_active is not
// a multiple of 32, switching the packet content mid-serialization -- audible as
// broken audio in that mode (subframe parity + sample pairing garbage).
//----------------------------------------------------------------------------
`default_nettype none

// One encoder + raster + island decoder/checker. Counters are read
// hierarchically by the top-level verdict block.
module di_bch_check #(
    parameter logic [11:0] H_ACTIVE = 12'd64,
    parameter logic [11:0] V_ACTIVE = 12'd4,
    parameter logic [11:0] H_TOTAL  = 12'd280,
    parameter logic [11:0] V_TOTAL  = 12'd8,
    parameter logic [4:0]  NPACK    = 5'd4
) (
    input wire logic clk,
    input wire logic rst_n
);

  // ── Stimulus: free-running raster + deterministic pixels/audio ────────────
  logic [11:0] cx, cy;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cx <= 12'd0;
      cy <= 12'd0;
    end else if (cx == H_TOTAL - 12'd1) begin
      cx <= 12'd0;
      cy <= (cy == V_TOTAL - 12'd1) ? 12'd0 : cy + 12'd1;
    end else begin
      cx <= cx + 12'd1;
    end
  end
  logic [7:0] rgb_r, rgb_g, rgb_b;
  always_comb begin
    rgb_r = cx[7:0] ^ cy[7:0];
    rgb_g = cx[7:0] + cy[7:0];
    rgb_b = ~cx[7:0];
  end
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
  ) u_enc (
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
      .tmds_r      (tmds_r),
      .tmds_g      (tmds_g),
      .tmds_b      (tmds_b)
  );

  // ── TERC4 decode (inverse of hdmi_channel's table); bit4 = valid ──────────
  function automatic logic [4:0] terc4_dec(input logic [9:0] s);
    case (s)
      10'b1010011100: terc4_dec = 5'b1_0000;
      10'b1001100011: terc4_dec = 5'b1_0001;
      10'b1011100100: terc4_dec = 5'b1_0010;
      10'b1011100010: terc4_dec = 5'b1_0011;
      10'b0101110001: terc4_dec = 5'b1_0100;
      10'b0100011110: terc4_dec = 5'b1_0101;
      10'b0110001110: terc4_dec = 5'b1_0110;
      10'b0100111100: terc4_dec = 5'b1_0111;
      10'b1011001100: terc4_dec = 5'b1_1000;
      10'b0100111001: terc4_dec = 5'b1_1001;
      10'b0110011100: terc4_dec = 5'b1_1010;
      10'b1011000110: terc4_dec = 5'b1_1011;
      10'b1010001110: terc4_dec = 5'b1_1100;
      10'b1001110001: terc4_dec = 5'b1_1101;
      10'b0101100011: terc4_dec = 5'b1_1110;
      10'b1011000011: terc4_dec = 5'b1_1111;
      default:        terc4_dec = 5'b0_0000;
    endcase
  endfunction

  // One step of the systematic BCH(8) encoder (generator 0x83), as hdmi_packet.
  function automatic logic [7:0] next_ecc(input logic [7:0] ecc, input logic b);
    next_ecc = (ecc >> 1) ^ ((ecc[0] ^ b) ? 8'h83 : 8'h00);
  endfunction

  localparam logic [9:0] DGUARD = 10'b0100110011;  // island guard, ch1/ch2
  localparam logic [9:0] CTL01 = 10'b0010101011;  // island preamble, ch1/ch2

  // ── Island capture + verdict counters (read by the top level) ─────────────
  integer islands = 0, pkts = 0;
  integer bch_fail = 0, dec_fail = 0, len_fail = 0;
  integer n_aud = 0, n_acr = 0, n_avi = 0, n_null = 0, n_other = 0;
  integer pair_fail = 0, iec_fail = 0, acrn_fail = 0, csum_fail = 0;
  integer hdr_fail = 0, b_fail = 0, n_b = 0, d3_fail = 0;
  integer aframes = 0, last_b = -1;  // audio frames seen, frame of the last B

  // Stimulus pair invariant: samples latched on the same tick t satisfy
  // 3*(L0 + 7t) + 7*(R0 - 3t) == 3*L0 + 7*R0 (mod 2^16).
  localparam logic [15:0] PAIRC = 16'(3 * 16'h1234 + 7 * 16'hABCD);

  integer bidx = 0;
  logic   inbody = 1'b0;
  integer pre_run = 0, grd_run = 0;
  logic hbuf[0:511], d3buf[0:511];
  logic [3:0] ebuf[0:511], obuf[0:511];

  task automatic check_island();
    integer p, t, i;
    logic [31:0] hw;
    logic [63:0] sub [4];
    logic [63:0] sw;
    logic [ 7:0] ecc;
    logic [15:0] sl, sr;
    logic [11:0] csum;
    logic        ok;
    islands = islands + 1;
    if (bidx != 32 * NPACK) begin
      len_fail = len_fail + 1;
      return;
    end
    for (t = 0; t < bidx; t = t + 1) if (d3buf[t] != (t != 0)) d3_fail = d3_fail + 1;
    for (p = 0; p < NPACK; p = p + 1) begin
      ok = 1'b1;
      // Header: 24 data bits + 8 ECC, one bit per pixel (ch0 nibble bit 2).
      hw = 32'd0;
      for (t = 0; t < 32; t = t + 1) hw[t] = hbuf[p*32+t];
      ecc = 8'd0;
      for (t = 0; t < 24; t = t + 1) ecc = next_ecc(ecc, hw[t]);
      if (hw[31:24] != ecc) ok = 1'b0;
      // Subpackets: 56 data bits + 8 ECC, two bits per pixel (ch1 even, ch2 odd).
      for (i = 0; i < 4; i = i + 1) begin
        sw = 64'd0;
        for (t = 0; t < 32; t = t + 1) begin
          sw[2*t]   = ebuf[p*32+t][i];
          sw[2*t+1] = obuf[p*32+t][i];
        end
        ecc = 8'd0;
        for (t = 0; t < 56; t = t + 1) ecc = next_ecc(ecc, sw[t]);
        if (sw[63:56] != ecc) ok = 1'b0;
        sub[i] = sw;
      end
      pkts = pkts + 1;
      if (!ok) bch_fail = bch_fail + 1;
      else begin
        case (hw[7:0])  // HB0 = packet type
          8'h02: begin  // Audio Sample (layout 0, 4 subframes)
            n_aud = n_aud + 1;
            if (hw[15:8] != 8'h0F || hw[19:16] != 4'h0) hdr_fail = hdr_fail + 1;
            for (i = 0; i < 4; i = i + 1) begin
              // B.i: this subpacket's frame starts an IEC block, 192 frames
              // after the last
              if (hw[20+i]) begin
                n_b = n_b + 1;
                if (last_b >= 0 && aframes - last_b != 192) b_fail = b_fail + 1;
                last_b = aframes;
              end else if (last_b >= 0 && aframes - last_b == 192) begin
                b_fail = b_fail + 1;
              end
              aframes = aframes + 1;
              // {pr, csr, Ur, Vr, pl, csl, Ul, Vl, s24r[23:0], s24l[23:0]};
              // 16-bit samples ride in the top 16 of each 24-bit field.
              sl      = sub[i][23:8];
              sr      = sub[i][47:32];
              if (16'(16'd3 * sl + 16'd7 * sr) != PAIRC) pair_fail = pair_fail + 1;
              // IEC-60958 even parity: P covers CS + the 24-bit sample (U=V=0).
              if ((sub[i][51] != (sub[i][50] ^ (^sub[i][23:0]))) ||
                  (sub[i][55] != (sub[i][54] ^ (^sub[i][47:24]))))
                iec_fail = iec_fail + 1;
            end
          end
          8'h01: begin  // ACR: N == 6144 in all four copies
            n_acr = n_acr + 1;
            for (i = 0; i < 4; i = i + 1)
            if ({sub[i][39:32], sub[i][47:40], sub[i][55:48]} != 24'd6144)
              acrn_fail = acrn_fail + 1;
          end
          8'h82: begin  // AVI InfoFrame: checksum incl. header
            n_avi = n_avi + 1;
            csum  = 12'(hw[7:0]) + 12'(hw[15:8]) + 12'(hw[23:16]);
            for (i = 0; i < 2; i = i + 1)
            for (t = 0; t < 7; t = t + 1) csum = csum + 12'(sub[i][t*8+:8]);
            if (csum[7:0] != 8'd0) csum_fail = csum_fail + 1;
          end
          8'h00:   n_null = n_null + 1;
          default: n_other = n_other + 1;
        endcase
      end
    end
  endtask

  // Sample on negedge (all posedge NBAs settled), like tb_di_equiv. The island
  // body is bounded by two-pixel guard bands on ch1+ch2; requiring the CTL01
  // island preamble right before the leading guard rejects any coincidental
  // video symbols.
  logic [4:0] d0, d1, d2;
  always @(negedge clk) begin
    if (rst_n) begin
      d0 = terc4_dec(tmds_b);
      d1 = terc4_dec(tmds_g);
      d2 = terc4_dec(tmds_r);
      if (!inbody) begin
        if (tmds_g == DGUARD && tmds_r == DGUARD) begin
          grd_run = grd_run + 1;
        end else begin
          if (tmds_g == CTL01 && tmds_r == CTL01) pre_run = pre_run + 1;
          else pre_run = 0;
          grd_run = 0;
        end
        if (grd_run == 2 && pre_run >= 2) begin
          inbody  = 1'b1;
          bidx    = 0;
          grd_run = 0;
          pre_run = 0;
        end
      end else begin
        if (tmds_g == DGUARD && tmds_r == DGUARD) begin
          inbody = 1'b0;
          check_island();
        end else if (!d0[4] || !d1[4] || !d2[4]) begin
          dec_fail = dec_fail + 1;
          inbody   = 1'b0;
        end else if (bidx >= 32 * NPACK) begin
          len_fail = len_fail + 1;
          inbody   = 1'b0;
        end else begin
          hbuf[bidx]  = d0[2];  // island_data[2] = packet header bit
          d3buf[bidx] = d0[3];  // island_data[3] = D3
          ebuf[bidx]  = d1[3:0];  // ch1 = subpacket even bits
          obuf[bidx]  = d2[3:0];  // ch2 = subpacket odd bits
          bidx        = bidx + 1;
        end
      end
    end
  end

endmodule

module tb_di_bch;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;
  initial begin
    repeat (8) @(posedge clk);
    rst_n = 1;
  end

  // Same compact raster as tb_di_equiv; only h_active differs between the two.
  //   aligned:   h_active = 64  (64 % 32 == 0;  di_start = 78,  78 % 32 == 14)
  //   unaligned: h_active = 48  (48 % 32 == 16; di_start = 62,  62 % 32 == 30 --
  //              the 1680x1050 class: 1680 % 32 == 16)
  di_bch_check #(
      .H_ACTIVE(12'd64)
  ) u_a (
      .clk  (clk),
      .rst_n(rst_n)
  );
  di_bch_check #(
      .H_ACTIVE(12'd48)
  ) u_u (
      .clk  (clk),
      .rst_n(rst_n)
  );

  function automatic integer inst_bad(input integer decf, input integer lenf, input integer bchf,
                                      input integer pairf, input integer iecf, input integer acrnf,
                                      input integer csumf, input integer isl, input integer aud,
                                      input integer acr, input integer avi, input integer hdrf,
                                      input integer bf, input integer nb, input integer d3f);
    inst_bad = (decf != 0) || (lenf != 0) || (bchf != 0) || (pairf != 0)
             || (iecf != 0) || (acrnf != 0) || (csumf != 0)
             || (hdrf != 0) || (bf != 0) || (d3f != 0)
             || (isl < 50) || (aud < 5) || (acr < 2) || (avi < 1) || (nb < 2);
  endfunction

  `define INST_ARGS(u) u.dec_fail, u.len_fail, u.bch_fail, u.pair_fail, \
      u.iec_fail, u.acrn_fail, u.csum_fail, u.islands, u.n_aud, u.n_acr, u.n_avi, \
      u.hdr_fail, u.b_fail, u.n_b, u.d3_fail

  initial begin
    #400000;  // ~40k pixels: hundreds of islands, dozens of audio/ACR packets
    $display(
        "tb_di_bch: aligned   h=64: islands=%0d pkts=%0d bch=%0d dec=%0d len=%0d pair=%0d iec=%0d acrn=%0d csum=%0d hdr=%0d b=%0d d3=%0d | aud=%0d acr=%0d avi=%0d null=%0d other=%0d blocks=%0d",
        u_a.islands, u_a.pkts, u_a.bch_fail, u_a.dec_fail, u_a.len_fail, u_a.pair_fail,
        u_a.iec_fail, u_a.acrn_fail, u_a.csum_fail, u_a.hdr_fail, u_a.b_fail, u_a.d3_fail,
        u_a.n_aud, u_a.n_acr, u_a.n_avi, u_a.n_null, u_a.n_other, u_a.n_b);
    $display(
        "tb_di_bch: unaligned h=48: islands=%0d pkts=%0d bch=%0d dec=%0d len=%0d pair=%0d iec=%0d acrn=%0d csum=%0d hdr=%0d b=%0d d3=%0d | aud=%0d acr=%0d avi=%0d null=%0d other=%0d blocks=%0d",
        u_u.islands, u_u.pkts, u_u.bch_fail, u_u.dec_fail, u_u.len_fail, u_u.pair_fail,
        u_u.iec_fail, u_u.acrn_fail, u_u.csum_fail, u_u.hdr_fail, u_u.b_fail, u_u.d3_fail,
        u_u.n_aud, u_u.n_acr, u_u.n_avi, u_u.n_null, u_u.n_other, u_u.n_b);
    if (inst_bad(`INST_ARGS(u_a)))
      $display(
          "tb_di_bch: FAIL (aligned h_active: island ECC/content errors or too little traffic)"
      );
    else if (inst_bad(`INST_ARGS(u_u)))
      $display(
          "tb_di_bch: FAIL (UNALIGNED h_active: island content corrupt -- packet window misalignment)"
      );
    else
      $display(
          "tb_di_bch: PASS (islands ECC+content clean at aligned AND unaligned h_active, %0d + %0d packets)",
          u_a.pkts,
          u_u.pkts
      );
    if (inst_bad(`INST_ARGS(u_a)) || inst_bad(`INST_ARGS(u_u))) $fatal(1);
    $finish;
  end
endmodule

`default_nettype wire

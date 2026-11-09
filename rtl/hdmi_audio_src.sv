// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// hdmi_audio_src.sv  --  HDMI data-island content + scheduler for L-PCM audio.
//
// Produces the 24-bit header and four 56-bit subpackets for whichever data-
// island packet should be sent next, and decides that schedule. We emit, per the
// HDMI 1.4b minimal-audio requirements (Section 7.3), in this priority order at
// each packet slot:
//
//   * Audio Clock Regeneration (ACR)  -- N + measured CTS, every N/128 samples
//   * Audio Sample (L-PCM, 2 channels) -- 4 IEC-60958 frames per packet, 16-bit
//                                         samples declared as 16, 20 or 24 bits
//   * General Control Packet           -- once per video field (no AV-Mute flag)
//   * AVI InfoFrame                    -- once per video field (RGB, the `vic` input)
//   * Audio InfoFrame                  -- once per video field (2ch L-PCM)
//   * Source Product Description       -- once per video field (the SPD_* parameters)
//   * Null                             -- when nothing else is pending
//
// The audio sample clock is a clock-enable derived from clk_pix, and the samples
// must arrive in that domain, so there is no clock-domain crossing. CTS is
// measured by counting pixel clocks across N/128 audio samples, which makes the
// regenerated audio clock track the real pixel clock exactly.
//
// Our own implementation; the IEC-60958 channel-status layout and packet byte
// maps follow the HDMI 1.4b / IEC-60958-3 tables.
//----------------------------------------------------------------------------
`default_nettype none

module hdmi_audio_src #(
    // Real pixel-clock frequency; used only to seed cts_value before the first
    // measurement completes. The sample-clock divider itself is the runtime
    // aud_div_max_i + aud_div_frac_i/256, which MUST match the board's real
    // pixel clock: a wrong value puts the delivered rate off the declared
    // 48 kHz and slips sinks that reference the declared rate, not the ACR.
    parameter int unsigned         CLK_PIX_HZ    = 75_000_000,
    // Source Product Description InfoFrame (CTA-861 6.5): what a sink lists as
    // the source. ASCII string literals, at most 8 and 16 characters; shorter
    // ones are sent left-aligned and zero-padded. SDI is the source device
    // information code (0x00 unknown, 0x08 game, 0x09 PC general, ...).
    parameter logic        [ 63:0] SPD_VENDOR    = "hh-hdmi",
    parameter logic        [127:0] SPD_PRODUCT   = "HDMI source",
    parameter logic        [  7:0] SPD_SDI       = 8'h00,
    // AVI InfoFrame Active Format Description (CTA-861 PB1 A0, PB2 R3-R0):
    // where the picture sits inside the 16:9 coded frame. With AVI_AFD_VALID
    // clear no format is signaled and the sink shows the whole frame; set it to
    // send AVI_AFD, e.g. 4'b1001 for a 4:3 picture pillarboxed in the center.
    parameter bit                  AVI_AFD_VALID = 1'b0,
    parameter logic        [  3:0] AVI_AFD       = 4'b1000
) (
    input  wire logic         clk_pix,
    input  wire logic         rst_n,
    input  wire logic [ 15:0] audio_l,
    input  wire logic [ 15:0] audio_r,
    input  wire logic [  1:0] aud_rate,         // 0 = 48 kHz, 1 = 44.1 kHz, 2 = 32 kHz
    input  wire logic [  1:0] aud_depth,        // 0 = 16-bit, 1 = 20-bit, 2 = 24-bit
    input  wire logic [  7:0] vic,              // AVI InfoFrame VIC (runtime; 0 = none)
    input  wire logic [ 12:0] aud_div_max_i,    // pixel-clocks per audio sample (runtime)
    input  wire logic [  7:0] aud_div_frac_i,   // + this /256 fractional pixel-clocks
    input  wire logic         packet_enable,    // 1-cycle at each 32-px boundary
    input  wire logic [  4:0] counter,          // pixel within current packet
    input  wire logic         video_field_end,
    output logic      [ 23:0] header,
    output logic      [223:0] subs
);

  // Sample-rate parameters, selected by aud_rate (HDMI Table 7-1/7-2). The
  // consumer picks the rate, normally from the sink's EDID Audio Data Block; 48 kHz
  // is the HDMI minimum every sink supports. N and N/128 are the standard
  // clock-independent HDMI values. The sample-clock divider is the runtime input
  // aud_div_max_i (Fpix/rate for the active mode and rate), so audio tracks the
  // chosen rate at every pixel clock, and CTS is measured, so the ACR stays
  // coherent with whatever the divider produces. CTS48 only seeds cts_value
  // before the first measurement completes.
  localparam int unsigned DIV48 = (CLK_PIX_HZ + 32'd24000) / 32'd48000;  // rounded
  localparam int unsigned CTS48 = 48 * DIV48;  // steady-state CTS seed (N/128=48)
  logic [19:0] acr_n;
  logic [ 6:0] acr_smp;  // N/128
  logic [ 3:0] fs_code;  // IEC-60958 Fs nibble
  always_comb begin
    case (aud_rate)
      2'd1: begin
        acr_n   = 20'd6272;
        acr_smp = 7'd49;
        fs_code = 4'b0000;
      end  // 44.1k
      2'd2: begin
        acr_n   = 20'd4096;
        acr_smp = 7'd32;
        fs_code = 4'b0011;
      end  // 32k
      default: begin
        acr_n   = 20'd6144;
        acr_smp = 7'd48;
        fs_code = 4'b0010;
      end  // 48k
    endcase
  end
  wire [12:0] aud_div_max = aud_div_max_i;
  // IEC-60958 word-length nibble (channel status): 16/20/24-bit.
  wire [3:0] wl_code = (aud_depth == 2'd2) ? 4'b1011 :  // 24-bit (max-len 24)
  (aud_depth == 2'd1) ? 4'b1010 :  // 20-bit (max-len 20)
  4'b0010;  // 16-bit (max-len 20)

  // Packet-type tags (internal numbering).
  localparam logic [2:0] PT_NULL = 3'd0, PT_ACR = 3'd1, PT_AUD = 3'd2,
                         PT_AVI = 3'd3, PT_AIF = 3'd4, PT_SPD = 3'd5, PT_GCP = 3'd6;

  // ── Audio sample clock-enable (rate from EDID) ───────────────────────────
  // aud_div_max is quasi-static (changes only on a mode/rate switch, while the pixel
  // domain is held in reset), so register the compare threshold. audio_en itself is
  // also a REGISTER: it fans out to every collector/ACR clock-enable, and at 150+
  // MHz the 13-bit compare cannot ride in those CE cones. The registered form is
  // exact: aud_div reaches thr (= max-1) at cycle t iff it equaled thr-1 at t-1 and
  // did not just wrap (audio_en clears aud_div to 0, and max >= 2 always).
  //
  // The divider is FRACTIONAL: the period alternates between aud_div_max and
  // aud_div_max+1 under an 8-bit phase accumulator of aud_div_frac_i, so the mean
  // period is exactly aud_div_max + frac/256 pixel clocks. Fpix/rate is rarely an
  // integer (74.25 MHz / 48 kHz = 1546.875): with the truncation error left in, the
  // delivered rate differs from the declared one. Sinks that use the declared
  // rate can exhaust their elastic buffering. frac=0 is an integer divider. The carry
  // settles into the threshold register two cycles after audio_en — thousands of
  // cycles before the count next approaches it.
  logic [12:0] aud_div, aud_div_thr_m1;
  logic       audio_en;
  logic [8:0] aud_frac_acc;  // [7:0] phase, [8] carry = +1 on this period
  always_ff @(posedge clk_pix) begin
    if (!rst_n) aud_frac_acc <= 9'd0;
    else if (audio_en) aud_frac_acc <= {1'b0, aud_frac_acc[7:0]} + {1'b0, aud_div_frac_i};
  end
  always_ff @(posedge clk_pix) aud_div_thr_m1 <= aud_div_max - 13'd2 + {12'd0, aud_frac_acc[8]};
  always_ff @(posedge clk_pix) begin
    if (!rst_n) begin
      aud_div  <= 13'd0;
      audio_en <= 1'b0;
    end else begin
      aud_div  <= audio_en ? 13'd0 : aud_div + 13'd1;
      audio_en <= ~audio_en && (aud_div == aud_div_thr_m1);
    end
  end

  // ── ACR: CTS measurement + request toggle every N/128 samples ────────────
  // acr_smp is quasi-static (a mux of aud_rate), so register the compare threshold
  // out of the per-sample path (it otherwise lands in the cts_value clock-enables).
  logic [5:0] acr_smp_m1;
  always_ff @(posedge clk_pix) acr_smp_m1 <= acr_smp[5:0] - 6'd1;
  logic [5:0] acr_cnt;
  logic [19:0] cts_counter, cts_value;
  logic acr_req;
  always_ff @(posedge clk_pix) begin
    if (!rst_n) begin
      acr_cnt     <= 6'd0;
      cts_counter <= 20'd1;
      cts_value   <= CTS48[19:0];
      acr_req     <= 1'b0;
    end else begin
      cts_counter <= cts_counter + 20'd1;
      if (audio_en) begin
        if (acr_cnt == acr_smp_m1) begin
          acr_cnt     <= 6'd0;
          acr_req     <= ~acr_req;
          cts_value   <= cts_counter;  // pixel clocks over N/128 samples = CTS
          cts_counter <= 20'd1;
        end else begin
          acr_cnt <= acr_cnt + 6'd1;
        end
      end
    end
  end

  // ── Audio sample FIFO (groups of 4 IEC frames) ────────────────────────────
  // The collector assembles 4 consecutive samples into one 128-bit group and
  // pushes it into a small FIFO; the scheduler pops exactly one group per audio
  // packet into stable per-packet registers (sl/sr), so a collector update
  // cannot change samples during a packet's 32-pixel serialization window.
  // The FIFO buffers audio across the data-island slots. Write and read are both
  // in clk_pix, so there is no clock-domain crossing.
  localparam int FIFO_DEPTH = 8;  // groups; 8 x 4 frames ~= 0.67 ms
  localparam int FIFO_AW = $clog2(FIFO_DEPTH);
  logic [127:0] afifo[FIFO_DEPTH];  // {l0,r0, l1,r1, l2,r2, l3,r3}
  logic [FIFO_AW-1:0] wr_ptr, rd_ptr;
  logic [FIFO_AW:0] fifo_count;
  wire fifo_empty = (fifo_count == '0);
  wire fifo_full = fifo_count[FIFO_AW];  // count == DEPTH

  // Stable per-packet sample registers (loaded by the scheduler on pop).
  logic [15:0] sl[4], sr[4];

  // Collector: assemble 4 frames, then present one group + a 1-cycle push pulse.
  logic [15:0] gl[4], gr[4];
  logic [  1:0] gidx;
  logic         grp_push;
  logic [127:0] grp_word;
  always_ff @(posedge clk_pix) begin
    if (!rst_n) begin
      gidx     <= 2'd0;
      grp_push <= 1'b0;
    end else begin
      grp_push <= 1'b0;
      if (audio_en) begin
        gl[gidx] <= audio_l;
        gr[gidx] <= audio_r;
        if (gidx == 2'd3) begin
          gidx     <= 2'd0;
          grp_word <= {gl[0], gr[0], gl[1], gr[1], gl[2], gr[2], audio_l, audio_r};
          grp_push <= 1'b1;
        end else begin
          gidx <= gidx + 2'd1;
        end
      end
    end
  end

  // FIFO write/read bookkeeping. The scheduler pulses grp_pop when it takes an
  // audio packet; a push that arrives while full is dropped (the depth is sized
  // for the supported modes' blanking intervals). The caller must provide
  // enough packet slots to sustain the configured sample rate.
  logic grp_pop;
  wire  do_push = grp_push & ~fifo_full;
  always_ff @(posedge clk_pix) begin
    if (!rst_n) begin
      wr_ptr     <= '0;
      rd_ptr     <= '0;
      fifo_count <= '0;
    end else begin
      if (do_push) begin
        afifo[wr_ptr] <= grp_word;
        wr_ptr        <= wr_ptr + 1'b1;
      end
      if (grp_pop) rd_ptr <= rd_ptr + 1'b1;
      fifo_count <= fifo_count + do_push - grp_pop;  // both same cycle => no change
    end
  end

  // ── Scheduler ─────────────────────────────────────────────────────────────
  logic [2:0] packet_type;
  logic acr_ack, gcp_sent, avi_sent, aif_sent, spd_sent;
  logic [7:0] frame_counter;  // IEC-60958 block position, 0..191, step 4
  always_ff @(posedge clk_pix) begin
    if (!rst_n) begin
      packet_type   <= PT_NULL;
      acr_ack       <= 1'b0;
      gcp_sent      <= 1'b0;
      avi_sent      <= 1'b0;
      aif_sent      <= 1'b0;
      spd_sent      <= 1'b0;
      frame_counter <= 8'd0;
      grp_pop       <= 1'b0;
    end else begin
      grp_pop <= 1'b0;
      if (video_field_end) begin
        gcp_sent <= 1'b0;
        avi_sent <= 1'b0;
        aif_sent <= 1'b0;
        spd_sent <= 1'b0;
      end
      if (packet_enable) begin
        if (acr_req != acr_ack) begin
          packet_type <= PT_ACR;
          acr_ack     <= acr_req;
        end else if (!fifo_empty) begin
          packet_type                                              <= PT_AUD;
          grp_pop                                                  <= 1'b1;
          // Latch the head group into the stable per-packet sample registers, so
          // the 32-pixel serialization always reads a frozen snapshot.
          {sl[0], sr[0], sl[1], sr[1], sl[2], sr[2], sl[3], sr[3]} <= afifo[rd_ptr];
        end else if (!gcp_sent) begin
          // General Control Packet, once per field: some sinks want it before
          // they lock. It asserts neither AV-Mute flag (see GCP_HDR below).
          packet_type <= PT_GCP;
          gcp_sent    <= 1'b1;
        end else if (!avi_sent) begin
          packet_type <= PT_AVI;
          avi_sent    <= 1'b1;
        end else if (!aif_sent) begin
          packet_type <= PT_AIF;
          aif_sent    <= 1'b1;
        end else if (!spd_sent) begin
          packet_type <= PT_SPD;
          spd_sent    <= 1'b1;
        end else begin
          packet_type <= PT_NULL;
        end
      end
      // Advance the IEC block position when an audio packet finishes.
      if (packet_type == PT_AUD && counter == 5'd31) begin
        frame_counter <= (frame_counter >= 8'd188) ? (frame_counter - 8'd188)
                                                   : (frame_counter + 8'd4);
      end
    end
  end

  // ── IEC-60958 channel status (consumer, L-PCM; Fs and word length runtime) ──
  // Bit layout (LSB first): grade, type, copyright, pre-emphasis[2:0], mode[1:0],
  // category[7:0], source#[3:0], channel#[3:0], Fs[3:0] (aud_rate), clk-acc[1:0],
  // 2'b0, word-length[3:0] (aud_depth), orig-Fs[3:0]; bits 40-191 are zero. The
  // two channels differ only in the channel number, 1 (left) or 2 (right).
  wire [39:0] cs_l = {
    4'd0, wl_code, 2'b00, 2'b00, fs_code, 4'd1, 4'd0, 8'd0, 2'd0, 3'd0, 1'b1, 2'b00
  };
  wire [39:0] cs_r = {
    4'd0, wl_code, 2'b00, 2'b00, fs_code, 4'd2, 4'd0, 8'd0, 2'd0, 3'd0, 1'b1, 2'b00
  };

  // ── ACR packet ───────────────────────────────────────────────────────────
  wire [55:0] acr_sub = {
    acr_n[7:0],
    acr_n[15:8],
    {4'd0, acr_n[19:16]},
    cts_value[7:0],
    cts_value[15:8],
    {4'd0, cts_value[19:16]},
    8'd0
  };
  localparam logic [23:0] ACR_HDR = {16'd0, 8'h01};  // every subpacket carries acr_sub

  // ── Audio sample packet ──────────────────────────────────────────────────
  logic [ 23:0] aud_hdr;
  logic [223:0] aud_subs;
  always_comb begin
    logic [7:0] idx;
    logic bsel, csl, csr, pl, pr;
    logic [23:0] s24l, s24r;
    logic [55:0] sub;
    logic [ 3:0] bbits;
    aud_subs = 224'd0;
    bbits    = 4'd0;
    for (int i = 0; i < 4; i++) begin
      // frame_counter is a multiple of 4 no larger than 188, so idx < 192.
      idx                = frame_counter + 8'(i);
      bsel               = (idx == 8'd0);
      bbits[i]           = bsel;
      csl                = (idx < 8'd40) ? cs_l[idx] : 1'b0;
      csr                = (idx < 8'd40) ? cs_r[idx] : 1'b0;
      s24l               = {sl[i], 8'd0};
      s24r               = {sr[i], 8'd0};
      pl                 = csl ^ (^s24l);  // even parity (user=valid=0)
      pr                 = csr ^ (^s24r);
      // {Pr, CSr, Ur, Vr, Pl, CSl, Ul, Vl, sample_r[23:0], sample_l[23:0]}
      sub                = {pr, csr, 1'b0, 1'b0, pl, csl, 1'b0, 1'b0, s24r, s24l};
      aud_subs[i*56+:56] = sub;
    end
    // Audio Sample Packet header (HDMI 1.4 Table 5-12):
    //   HB0 = 0x02 (type)
    //   HB1 = {rsvd[7:5]=0, layout[4]=0 (2 ch), sample_present.sp3..sp0[3:0]=1111}
    //   HB2 = {B.3..B.0[7:4] (IEC block start per subpacket), sample_flat.sp3..sp0[3:0]=0}
    // B belongs in the HIGH nibble of HB2. In the low nibble it reads as
    // sample_flat: the subpacket starting each IEC block is then marked a flatline
    // sample, and the sink never sees a block start, so it cannot frame the channel
    // status (sample rate, word length, PCM). sim/tb_di_bch checks both header bytes.
    aud_hdr = {{bbits, 4'd0}, 8'h0F, 8'h02};
  end

  // ── InfoFrame packets (checksum so all bytes sum to 0 mod 256) ───────────
  // AVI: RGB, IT content, the `vic` input.  Audio: 2-channel L-PCM. The 28 packet
  // bytes map straight onto the flat subpacket vector (byte k at bit k*8) — the
  // four 56-bit subpackets are just bytes 0-6, 7-13, 14-20, 21-27 of this word.
  localparam logic [23:0] AVI_HDR = {8'd13, 8'd2, 8'h82};
  localparam logic [23:0] AIF_HDR = {8'd10, 8'd1, 8'h84};

  // AVI body bytes 1..13 (byte 0 is the checksum, filled below).
  //   PB1: RGB (Y = 00); bit 4 (A0) = AVI_AFD_VALID, Active Format present
  //   PB2: [5:4] M = the coded frame's picture aspect, from the VIC;
  //        [3:0] R = AVI_AFD (1000 = same as the coded frame, the value
  //        CTA-861 asks for when A0 is 0)
  localparam logic [7:0] AVI_PB1 = {3'b000, AVI_AFD_VALID, 4'b0000};

  // Picture aspect of a CTA-861 VIC (Table 3): 01 = 4:3, 10 = 16:9, 00 = no
  // data. VIC 0 is not a CTA format, and the field cannot express the 64:27
  // and 256:135 formats, so those send no data, as CTA-861-F asks.
  function automatic logic [1:0] vic_aspect(input logic [7:0] v);
    case (v)
      8'd1, 8'd2, 8'd6, 8'd8, 8'd10, 8'd12, 8'd14, 8'd17, 8'd21, 8'd23,
      8'd25, 8'd27, 8'd29, 8'd35, 8'd37, 8'd42, 8'd44, 8'd48, 8'd50, 8'd52,
      8'd54, 8'd56, 8'd58:
      vic_aspect = 2'b01;
      8'd3, 8'd4, 8'd5, 8'd7, 8'd9, 8'd11, 8'd13, 8'd15, 8'd16, 8'd18,
      8'd19, 8'd20, 8'd22, 8'd24, 8'd26, 8'd28, 8'd30, 8'd31, 8'd32, 8'd33,
      8'd34, 8'd36, 8'd38, 8'd39, 8'd40, 8'd41, 8'd43, 8'd45, 8'd46, 8'd47,
      8'd49, 8'd51, 8'd53, 8'd55, 8'd57, 8'd59, 8'd60, 8'd61, 8'd62, 8'd63,
      8'd64, 8'd93, 8'd94, 8'd95, 8'd96, 8'd97, 8'd108, 8'd111, 8'd114,
      8'd117, 8'd118:
      vic_aspect = 2'b10;
      default: vic_aspect = 2'b00;
    endcase
  endfunction
  wire [7:0] AVI_PB2 = {2'b00, vic_aspect(vic), AVI_AFD_VALID ? AVI_AFD : 4'b1000};
  // PB3: ITC=1 (IT content -> sharp pixels, no overscan) + Q=10 (full-range RGB).
  // CE formats such as VIC 4 default to limited-range quantization (16-235); the
  // RGB this encoder carries is full-range (black at 0x00), so signal full range
  // explicitly or a strict sink crushes the blacks.
  localparam logic [7:0] AVI_PB3 = 8'h88;  // IT content, full-range RGB
  wire [7:0] AVI_PB4 = vic;  // VIC (runtime; 4 = 720p, 0 = no CEA VIC)
  wire [7:0] avi_csum = 8'd0 - (AVI_HDR[23:16] + AVI_HDR[15:8] + AVI_HDR[7:0]
                              + AVI_PB1 + AVI_PB2 + AVI_PB3 + AVI_PB4);
  // Bytes 0-4 (checksum, PB1-PB4); PB5-PB13 are zero.
  wire [39:0] avi_body = {AVI_PB4, AVI_PB3, AVI_PB2, AVI_PB1, avi_csum};

  // Audio InfoFrame body: PB1 = channel count (2ch -> CC=001, CT=refer-to-stream).
  localparam logic [7:0] AIF_PB1 = 8'h01;
  // PB2 = sample frequency [4:2] + sample size [1:0], stated EXPLICITLY rather than
  // "refer to stream header" (0): some sinks ignore refer-to-header and mute audio
  // unless the AIF carries the rate/size directly. Driven from the runtime rate/depth.
  logic [2:0] aif_sf;
  logic [1:0] aif_ss;
  always_comb begin
    case (aud_rate)
      2'd1:    aif_sf = 3'b010;   // 44.1 kHz
      2'd2:    aif_sf = 3'b001;   // 32 kHz
      default: aif_sf = 3'b011;   // 48 kHz
    endcase
    case (aud_depth)
      2'd1:    aif_ss = 2'b10;    // 20-bit
      2'd2:    aif_ss = 2'b11;    // 24-bit
      default: aif_ss = 2'b01;    // 16-bit
    endcase
  end
  wire [ 7:0] aif_pb2 = {3'b000, aif_sf, aif_ss};
  wire [ 7:0] aif_csum = 8'd0 - (AIF_HDR[23:16] + AIF_HDR[15:8] + AIF_HDR[7:0] + AIF_PB1 + aif_pb2);
  // Bytes 0-2 (checksum, PB1, PB2); PB3-PB10 are zero.
  wire [23:0] aif_body = {aif_pb2, AIF_PB1, aif_csum};

  // ── Source Product Description InfoFrame (the SPD_* parameters) ─────────
  // type 0x83, len 25: PB1-8 vendor name, PB9-24 product, PB25 source device.
  // A string literal sits right-justified in its parameter; left_align moves
  // its first character to the top byte, so character i is byte 15 - i.
  // The constant functions below run only at elaboration, so a coverage
  // tool would count their bodies as never executed.
  // verilator coverage_off
  function automatic logic [127:0] left_align(input logic [127:0] s);
    logic [127:0] r;
    r = s;
    for (int k = 0; k < 16; k++) if (r[127:120] == 8'h00) r = r << 8;
    return r;
  endfunction
  function automatic logic [7:0] byte_sum(input logic [127:0] s);
    logic [7:0] t;
    t = 8'h00;
    for (int k = 0; k < 16; k++) t = t + s[8*k+:8];
    return t;
  endfunction
  localparam logic [127:0] SPD_VEND_L = left_align({SPD_VENDOR, 64'd0});
  localparam logic [127:0] SPD_PROD_L = left_align(SPD_PRODUCT);
  localparam logic [23:0] SPD_HDR = {8'd25, 8'd1, 8'h83};
  localparam logic [7:0]   SPD_CSUM   = 8'd0 - (SPD_HDR[23:16] + SPD_HDR[15:8] + SPD_HDR[7:0]
                                                + byte_sum(
      SPD_VEND_L
  ) + byte_sum(
      SPD_PROD_L
  ) + SPD_SDI);
  function automatic logic [223:0] spd_body();
    logic [223:0] b;
    b         = 224'd0;
    b[0*8+:8] = SPD_CSUM;
    for (int i = 0; i < 8; i++) b[(1+i)*8+:8] = SPD_VEND_L[127-8*i-:8];
    for (int i = 0; i < 16; i++) b[(9+i)*8+:8] = SPD_PROD_L[127-8*i-:8];
    b[25*8+:8] = SPD_SDI;
    return b;
  endfunction
  localparam logic [223:0] SPD_SUBS = spd_body();
  // verilator coverage_on

  // ── General Control Packet (HDMI 5.3.5; not an InfoFrame, so no checksum) ──
  // HB0=0x03, HB1=HB2=0. Body PB0 = AVMUTE flags (bit0 Clear_AVMUTE, bit4
  // Set_AVMUTE), PB1 = color depth (0 = not indicated -> 24 bpp), PB2 = 0.
  // PB0 = 0x00: neither AVMUTE event is requested. The periodic GCP advertises
  // control/depth without repeatedly changing the sink's mute state.
  // BCH ECC is added by hdmi_packet.
  localparam logic [23:0] GCP_HDR = {8'h00, 8'h00, 8'h03};
  localparam logic [223:0] GCP_SUBS = 224'd0;  // PB0=0x00 (no AVMUTE event), CD not indicated

  // ── Output mux by current packet type ────────────────────────────────────
  always_comb begin
    case (packet_type)
      PT_ACR: begin
        header = ACR_HDR;
        subs   = {4{acr_sub}};
      end
      PT_AUD: begin
        header = aud_hdr;
        subs   = aud_subs;
      end
      PT_AVI: begin
        header = AVI_HDR;
        subs   = {184'd0, avi_body};
      end
      PT_AIF: begin
        header = AIF_HDR;
        subs   = {200'd0, aif_body};
      end
      PT_SPD: begin
        header = SPD_HDR;
        subs   = SPD_SUBS;
      end
      PT_GCP: begin
        header = GCP_HDR;
        subs   = GCP_SUBS;
      end
      default: begin
        header = 24'd0;
        subs   = 224'd0;
      end  // Null
    endcase
  end

endmodule

`default_nettype wire

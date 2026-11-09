// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// hdmi_encoder.sv  --  full HDMI (not DVI) TMDS generator with audio islands.
//
// The RUNTIME-RECONFIGURABLE HDMI TMDS path: the line/frame geometry is a set of
// timing inputs, so one encoder instance drives any 60 Hz mode the mode controller
// selects. Tie the timing inputs to constants and synthesis folds it back to a fixed
// size (e.g. CEA-861 VIC 4, 1280x720p).
//
// Given the scanout's pixel coordinate (cx,cy) and the registered RGB for that
// pixel, it sequences the HDMI line into video / video-guard / control(+preamble)
// / data-island periods and drives three hdmi_channel lanes. Audio (L-PCM) rides
// in the data islands via hdmi_audio_src + hdmi_packet; the number of data-island
// packets per line (di_npackets) is sized to the mode's horizontal blanking.
//
// Pipeline (matched depths keep guards/preamble/island/data consistent):
//   cx,cy ─▶ stageB period flags (reg) ─▶ stageC mode/data (reg) ─▶ lane (reg).
// `rgb` must lag `cx` by one pixel (as the scanout provides) so video_data
// lines up with `mode`.
//----------------------------------------------------------------------------
`default_nettype none

// Define HDMI_DVI_ONLY (e.g. via the build, or a `define here) for a diagnostic
// DVI-only build: video + sync only, no data islands / InfoFrames. Used to tell a
// TMDS-lock failure from a data-island/InfoFrame rejection on strict sinks.

module hdmi_encoder #(
    // Pipeline the data-island packet content: register header/subs at the audio
    // source's output and prepare each packet one pixel earlier, so the per-pixel
    // BCH accumulate (hdmi_packet) starts from a register instead of the long
    // audio-parity + packet-type mux cone. 1 (the default) = pipelined, which
    // closes ~150 MHz and, by shrinking the BCH mux cone, also relieves fabric
    // congestion around it. 0 = the unpipelined path. The tmds output is
    // bit-identical either way, with one pixel more data-island latency that the
    // sink re-locks to (sim/tb_di_equiv).
    parameter bit           DI_PIPE       = 1'b1,
    // The Source Product Description InfoFrame: the name a sink lists for this
    // source. See hdmi_audio_src for the format.
    parameter logic [ 63:0] SPD_VENDOR    = "hh-hdmi",
    parameter logic [127:0] SPD_PRODUCT   = "HDMI source",
    parameter logic [  7:0] SPD_SDI       = 8'h00,
    // The AVI InfoFrame's Active Format Description; see hdmi_audio_src.
    parameter bit           AVI_AFD_VALID = 1'b0,
    parameter logic [  3:0] AVI_AFD       = 4'b1000
) (
    input wire logic clk_pix,
    input wire logic rst_n,

    // ── Runtime timing (drive from the mode table; constants fold to fixed) ──
    input wire logic [11:0] h_active,     // visible columns (e.g. 1280)
    input wire logic [11:0] v_active,     // visible rows    (e.g. 720)
    input wire logic [11:0] h_total,      // total columns incl. blanking (1650)
    input wire logic [11:0] v_total,      // total rows incl. blanking (750)
    input wire logic [11:0] h_sync_off,   // h_active -> hsync start (front porch, 110)
    input wire logic [11:0] h_sync_wid,   // hsync width (40)
    input wire logic [11:0] v_sync_off,   // v_active -> vsync start (5)
    input wire logic [11:0] v_sync_wid,   // vsync width (5)
    input wire logic        h_pol,        // 1 = active-high hsync (positive)
    input wire logic        v_pol,        // 1 = active-high vsync (positive)
    input wire logic [ 4:0] di_npackets,  // packets per line (1..18, must fit blanking)
    input wire logic [ 7:0] vic,          // AVI InfoFrame VIC (4 = 720p; 0 = none)
    input wire logic [12:0] aud_div_max,  // pixel-clocks per audio sample (Fpix/rate)
    input wire logic [ 7:0] aud_div_frac, // + this /256 fractional pixel-clocks
                                          // (0 = plain integer divider)

    input  wire logic [11:0] cx,         // pixel column (leads rgb by 1)
    input  wire logic [11:0] cy,         // pixel row
    input  wire logic [ 7:0] rgb_r,
    input  wire logic [ 7:0] rgb_g,
    input  wire logic [ 7:0] rgb_b,
    input  wire logic [15:0] audio_l,
    input  wire logic [15:0] audio_r,
    input  wire logic [ 1:0] aud_rate,   // 0 = 48 kHz, 1 = 44.1 kHz, 2 = 32 kHz
    input  wire logic [ 1:0] aud_depth,  // 0 = 16-bit, 1 = 20-bit, 2 = 24-bit
    output logic      [ 9:0] tmds_r,
    output logic      [ 9:0] tmds_g,
    output logic      [ 9:0] tmds_b
);

  localparam int DI_PRE = 14;  // h_active -> first data-island packet (fixed offset)

  // ── Derived geometry, REGISTERED out of the per-pixel critical path ───────
  // With fixed timing these would be localparams (free); with runtime timing they are
  // adders, which fail timing above ~75 MHz if left in the comparison path. They are
  // quasi-static (change only on a mode switch, when the pipeline is in reset), so
  // register them once and compare cx/cy against the registers.
  logic [11:0] hs_beg, hs_end, vs_beg_m1, vs_end_m1, vs_beg, vs_end;
  logic [11:0] di_start, di_end, di_start_m2, di_start_m10, di_end_p2;
  logic [11:0] ht_m2, ht_m10, va_m1, ha_m1, ha_m2, vt_m1;
  always_ff @(posedge clk_pix) begin
    hs_beg       <= h_active + h_sync_off;
    hs_end       <= h_active + h_sync_off + h_sync_wid;
    vs_beg       <= v_active + v_sync_off;
    vs_end       <= v_active + v_sync_off + v_sync_wid;
    vs_beg_m1    <= v_active + v_sync_off - 12'd1;
    vs_end_m1    <= v_active + v_sync_off + v_sync_wid - 12'd1;
    di_start     <= h_active + DI_PRE[11:0];
    di_end       <= h_active + DI_PRE[11:0] + {di_npackets, 5'd0};
    di_start_m2  <= h_active + DI_PRE[11:0] - 12'd2;
    di_start_m10 <= h_active + DI_PRE[11:0] - 12'd10;
    di_end_p2    <= h_active + DI_PRE[11:0] + {di_npackets, 5'd0} + 12'd2;
    ht_m2        <= h_total - 12'd2;
    ht_m10       <= h_total - 12'd10;
    va_m1        <= v_active - 12'd1;
    ha_m1        <= h_active - 12'd1;
    ha_m2        <= h_active - 12'd2;
    vt_m1        <= v_total - 12'd1;
  end

  // ── Sync, from cx/cy (registered in Stage B): pulse, then polarity ───────
  // vsync edges are aligned to the hsync start (CEA convention).
  logic hs_pulse, vs_pulse, hsync, vsync;
  always_comb begin
    hs_pulse = (cx >= hs_beg) && (cx < hs_end);
    if (cy == vs_beg_m1) vs_pulse = (cx >= hs_beg);
    else if (cy == vs_end_m1) vs_pulse = (cx < hs_beg);
    else vs_pulse = (cy >= vs_beg) && (cy < vs_end);
    hsync = hs_pulse ^ ~h_pol;  // positive (h_pol=1): asserted high during pulse
    vsync = vs_pulse ^ ~v_pol;
  end

  wire line_active = (cy == vt_m1) || (cy < va_m1);  // VG/VP gating
  wire di_inst = (cx >= di_start) && (cx < di_end);

  // packet_enable / video_field_end feed the audio scheduler's clock-enable cone
  // (packet-type priority chain + the sample-FIFO pop), which at 150+ MHz cannot
  // also absorb these cx compares. Register them with a one-pixel LOOKAHEAD (compare
  // against the next cx) so the registered pulse lands on exactly the same cycle as
  // an unregistered compare would -- bit-identical, just a register in the path. The
  // cx+1 line-wrap case needs no special handling: at cx == h_total-1 the lookahead
  // value h_total is outside [di_start, di_end) and != ha_m1, so both terms are 0
  // there, matching cx == 0 (video, not island).
  //
  // packet_enable must fire at the FIRST pixel of each 32-pixel packet window --
  // the windows start at di_start + 32k, so the low-bits match is against
  // di_start[4:0] (quasi-static, registered above), NOT a constant. A constant
  // (`== 5'd14`, DI_PRE for h_active % 32 == 0) fires mid-window for any other
  // h_active -- 1680x1050 (1680 % 32 == 16) would switch the packet content
  // mid-serialization, corrupting every data island in that mode with a
  // self-consistent ECC (broken audio). sim/tb_di_bch.sv checks both cases.
  wire [11:0] cx_p1 = cx + 12'd1;
  logic packet_enable, video_field_end;
  always_ff @(posedge clk_pix) begin
    if (!rst_n) begin
      packet_enable   <= 1'b0;
      video_field_end <= 1'b0;
    end else begin
      packet_enable   <= (cx_p1 >= di_start) && (cx_p1 < di_end) && (cx_p1[4:0] == di_start[4:0]);
      video_field_end <= (cx == ha_m2) && (cy == va_m1);
    end
  end

  // ── Stage B: registered period flags, and the syncs beside them ──────────
  // cx leads the pixel data by one clock, so a flag registered from cx lines up
  // with its pixel. The syncs (and di_rest, which rides with them into the
  // islands) are registered here for the same reason; unregistered they would
  // lead the video by one pixel (checked by sim/tb_sync_timing).
  // di_rest is channel 0's D3 in the island: 0 on the island's first pixel
  // (the first packet's first), 1 on every other (HDMI 1.4 Figure 5-3).
  logic video_data_period, video_guard, video_preamble;
  logic data_island_period, data_island_guard, data_island_preamble;
  logic hsync_b, vsync_b, di_rest_b;
  always_ff @(posedge clk_pix) begin
    if (!rst_n) begin
      video_data_period    <= 1'b0;
      video_guard          <= 1'b0;
      video_preamble       <= 1'b0;
      data_island_period   <= 1'b0;
      data_island_guard    <= 1'b0;
      data_island_preamble <= 1'b0;
      hsync_b              <= ~h_pol;
      vsync_b              <= ~v_pol;
      di_rest_b            <= 1'b1;
    end else begin
      hsync_b <= hsync;
      vsync_b <= vsync;
      di_rest_b <= (cx != di_start);
      video_data_period <= (cx < h_active) && (cy < v_active);
      video_guard <= (cx >= ht_m2) && (cx < h_total) && line_active;
      video_preamble <= (cx >= ht_m10) && (cx < ht_m2) && line_active;
      data_island_period <= di_inst;
      data_island_guard    <= ((cx >= di_start_m2) && (cx < di_start)) ||
                              ((cx >= di_end) && (cx < di_end_p2));
      data_island_preamble <= (cx >= di_start_m10) && (cx < di_start_m2);
    end
  end

  // ── Packet content + assembler ───────────────────────────────────────────
  logic [ 23:0] header;
  logic [223:0] subs;
  logic [  8:0] packet_data;
  logic [  4:0] packet_counter;

  hdmi_audio_src #(
      .SPD_VENDOR   (SPD_VENDOR),
      .SPD_PRODUCT  (SPD_PRODUCT),
      .SPD_SDI      (SPD_SDI),
      .AVI_AFD_VALID(AVI_AFD_VALID),
      .AVI_AFD      (AVI_AFD)
  ) u_audio (
      .clk_pix        (clk_pix),
      .rst_n          (rst_n),
      .audio_l        (audio_l),
      .audio_r        (audio_r),
      .aud_rate       (aud_rate),
      .aud_depth      (aud_depth),
      .vic            (vic),
      .aud_div_max_i  (aud_div_max),
      .aud_div_frac_i (aud_div_frac),
      .packet_enable  (packet_enable),
      .counter        (packet_counter),
      .video_field_end(video_field_end),
      .header         (header),
      .subs           (subs)
  );

  hdmi_packet #(
      .DI_PIPE(DI_PIPE)
  ) u_packet (
      .clk_pix           (clk_pix),
      .rst_n             (rst_n),
      .data_island_period(data_island_period),
      .header            (header),
      .subs              (subs),
      .packet_data       (packet_data),
      .counter           (packet_counter)
  );

  // ── DI_PIPE alignment: hdmi_packet's DI_PIPE delays packet_data (and the packet
  // internal BCH counter) by one pixel, so delay the rest of the data-island datapath -- the
  // period flags, the video pixel, and sync -- by one pixel too, and Stage C then
  // stays aligned. The whole encoder output shifts one pixel (harmless: the sink
  // re-locks), and it is otherwise bit-identical (sim/tb_di_equiv). DI_PIPE=0 wires
  // the signals straight through.
  logic vdp_c, vg_c, vpre_c, dip_c, dig_c, dipre_c;
  logic [7:0] r_c, g_c, b_c;
  logic vs_c, hs_c, di_rest_c;
  generate
    if (DI_PIPE) begin : g_align
      logic vdp_q, vg_q, vpre_q, dip_q, dig_q, dipre_q;
      logic [7:0] r_q, g_q, b_q;
      logic vs_q, hs_q, di_rest_q;
      always_ff @(posedge clk_pix) begin
        vdp_q     <= video_data_period;
        vg_q      <= video_guard;
        vpre_q    <= video_preamble;
        dip_q     <= data_island_period;
        dig_q     <= data_island_guard;
        dipre_q   <= data_island_preamble;
        r_q       <= rgb_r;
        g_q       <= rgb_g;
        b_q       <= rgb_b;
        vs_q      <= vsync_b;
        hs_q      <= hsync_b;
        di_rest_q <= di_rest_b;
      end
      assign vdp_c     = vdp_q;
      assign vg_c      = vg_q;
      assign vpre_c    = vpre_q;
      assign dip_c     = dip_q;
      assign dig_c     = dig_q;
      assign dipre_c   = dipre_q;
      assign r_c       = r_q;
      assign g_c       = g_q;
      assign b_c       = b_q;
      assign vs_c      = vs_q;
      assign hs_c      = hs_q;
      assign di_rest_c = di_rest_q;
    end else begin : g_thru
      assign vdp_c     = video_data_period;
      assign vg_c      = video_guard;
      assign vpre_c    = video_preamble;
      assign dip_c     = data_island_period;
      assign dig_c     = data_island_guard;
      assign dipre_c   = data_island_preamble;
      assign r_c       = rgb_r;
      assign g_c       = rgb_g;
      assign b_c       = rgb_b;
      assign vs_c      = vsync_b;
      assign hs_c      = hsync_b;
      assign di_rest_c = di_rest_b;
    end
  endgenerate

  // ── Stage C: mode + lane data ────────────────────────────────────────────
  logic [ 2:0] mode;
  logic [23:0] video_data;
  // {CTL2, CTL0, VSYNC, HSYNC}. CTL0 marks both preambles and CTL2 the data
  // island's preamble; CTL1 and CTL3 are always 0, tied at the lanes.
  logic [ 3:0] control_data;
  logic [11:0] island_data;
  always_ff @(posedge clk_pix) begin
    if (!rst_n) begin
      mode         <= 3'd0;
      video_data   <= 24'd0;
      control_data <= 4'd0;
      island_data  <= 12'd0;
    end else begin
`ifdef HDMI_DVI_ONLY
      mode         <= vdp_c ? 3'd1 : 3'd0;
      video_data   <= {r_c, g_c, b_c};  // ch2=R, ch1=G, ch0=B
      control_data <= {2'b0, vs_c, hs_c};
`else
      mode         <= dig_c ? 3'd4 : dip_c ? 3'd3 : vg_c ? 3'd2 : vdp_c ? 3'd1 : 3'd0;
      video_data   <= {r_c, g_c, b_c};  // ch2=R, ch1=G, ch0=B
      control_data <= {dipre_c, vpre_c || dipre_c, vs_c, hs_c};
`endif
      island_data[11:4] <= packet_data[8:1];
      island_data[3]    <= di_rest_c;
      island_data[2]    <= packet_data[0];
      island_data[1:0]  <= {vs_c, hs_c};
    end
  end

  // ── Three TMDS lanes ──────────────────────────────────────────────────────
  hdmi_channel #(
      .CN(0)
  ) u_ch0 (
      .clk_pix     (clk_pix),
      .video_data  (video_data[7:0]),
      .island_data (island_data[3:0]),
      .control_data(control_data[1:0]),
      .mode        (mode),
      .tmds        (tmds_b)
  );
  hdmi_channel #(
      .CN(1)
  ) u_ch1 (
      .clk_pix     (clk_pix),
      .video_data  (video_data[15:8]),
      .island_data (island_data[7:4]),
      .control_data({1'b0, control_data[2]}),
      .mode        (mode),
      .tmds        (tmds_g)
  );
  hdmi_channel #(
      .CN(2)
  ) u_ch2 (
      .clk_pix     (clk_pix),
      .video_data  (video_data[23:16]),
      .island_data (island_data[11:8]),
      .control_data({1'b0, control_data[3]}),
      .mode        (mode),
      .tmds        (tmds_r)
  );

endmodule

`default_nettype wire

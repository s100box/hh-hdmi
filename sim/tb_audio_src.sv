// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_audio_src.sv -- hdmi_audio_src alone: every packet it builds, at every
// rate and depth, against tables written from the specs.
//
// The bench drives the island schedule the way hdmi_encoder does: lines of
// idle pixels followed by a run of 32-pixel packet windows, packet_enable on
// each window's first pixel, the packet counter running 0..31 through it, and
// video_field_end once per field. It reads each packet's header and
// subpackets in the window and checks, by packet type:
//
//   * Audio Sample (HB0 0x02): HB1 0x0F, sample_flat clear, the B flag on the
//     subpacket that starts each 192-frame IEC 60958 block and no other; each
//     subframe's even parity; the channel-status bit of every frame against the
//     IEC 60958-3 consumer layout (channel 1 or 2, the sample rate, the word
//     length); and the samples themselves, in order, against a scoreboard of
//     what the source latched on each sample tick: none lost, repeated or torn.
//   * ACR (0x01): N for the rate (HDMI Table 7-1/7-2: 6144, 6272, 4096) in all
//     four subpackets, and CTS equal to the pixel clocks across N/128 sample
//     periods of aud_div_max + aud_div_frac/256, to one clock.
//   * Audio InfoFrame (0x84): version 1, length 10, two channels, the sample
//     frequency and size codes of CTA-861 Table 27/28, a clean checksum.
//   * AVI InfoFrame (0x82): for every VIC from 0 to 255, PB4 = the VIC and the
//     picture aspect of CTA-861 Table 3 (4:3, 16:9, or none for VIC 0, the
//     64:27 and 256:135 formats and every code above 127); PB3 = 0x88; a clean
//     checksum.
//   * GCP (0x03): an all-zero body. SPD (0x83): a clean checksum.
//   * Each field carries GCP, AVI, AIF and SPD once, and Null fills the rest.
//
// Phases: the four rates (including the undefined code 3, which falls back to
// 48 kHz) crossed with the four depths (code 3 falls back to 16-bit) and a
// spread of integer and fractional dividers; a VIC sweep; a run with the
// islands withheld until the sample FIFO overflows (whole groups are dropped,
// the ones kept stay intact and in order); and a reset in mid-stream.
//----------------------------------------------------------------------------
`default_nettype none

module tb_audio_src;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic         rst_n = 1'b0;
  logic [ 15:0] audio_l = 16'd0;
  logic [ 15:0] audio_r = 16'd0;
  logic [  1:0] aud_rate = 2'd0;
  logic [  1:0] aud_depth = 2'd0;
  logic [  7:0] vic = 8'd4;
  logic [ 12:0] div_max = 13'd40;
  logic [  7:0] div_frac = 8'd0;
  logic         packet_enable = 1'b0;
  logic [  4:0] counter = 5'd0;
  logic         video_field_end = 1'b0;
  wire  [ 23:0] header;
  wire  [223:0] subs;

  hdmi_audio_src dut (
      .clk_pix        (clk),
      .rst_n          (rst_n),
      .audio_l        (audio_l),
      .audio_r        (audio_r),
      .aud_rate       (aud_rate),
      .aud_depth      (aud_depth),
      .vic            (vic),
      .aud_div_max_i  (div_max),
      .aud_div_frac_i (div_frac),
      .packet_enable  (packet_enable),
      .counter        (counter),
      .video_field_end(video_field_end),
      .header         (header),
      .subs           (subs)
  );

  // ---- reference tables ---------------------------------------------------------
  // CTA-861 Table 3: picture aspect of each VIC that has one; 2'b00 otherwise.
  function automatic logic [1:0] ref_aspect(input integer v);
    integer a43[] = '{
        1,
        2,
        6,
        8,
        10,
        12,
        14,
        17,
        21,
        23,
        25,
        27,
        29,
        35,
        37,
        42,
        44,
        48,
        50,
        52,
        54,
        56,
        58
    };
    integer a169[] = '{
        3,
        4,
        5,
        7,
        9,
        11,
        13,
        15,
        16,
        18,
        19,
        20,
        22,
        24,
        26,
        28,
        30,
        31,
        32,
        33,
        34,
        36,
        38,
        39,
        40,
        41,
        43,
        45,
        46,
        47,
        49,
        51,
        53,
        55,
        57,
        59,
        60,
        61,
        62,
        63,
        64,
        93,
        94,
        95,
        96,
        97,
        108,
        111,
        114,
        117,
        118
    };
    foreach (a43[i]) if (a43[i] == v) return 2'b01;
    foreach (a169[i]) if (a169[i] == v) return 2'b10;
    return 2'b00;
  endfunction

  function automatic integer eff_rate(input logic [1:0] r);  // code 3 -> 48 kHz
    return (r == 2'd3) ? 0 : r;
  endfunction
  function automatic integer eff_depth(input logic [1:0] d);  // code 3 -> 16-bit
    return (d == 2'd3) ? 0 : d;
  endfunction

  function automatic integer ref_n(input logic [1:0] r);
    case (eff_rate(
        r
    ))
      1: return 6272;
      2: return 4096;
      default: return 6144;
    endcase
  endfunction

  // IEC 60958-3 consumer channel status, bit k of the 192-bit block (k = 0 is
  // the first bit sent): bit 2 = 1 (copying permitted), bits 20-23 the
  // channel number, bits 24-27 the sample frequency, bits 32-35 the word
  // length. Values are written in transmission order.
  function automatic logic ref_cs(input integer k, input integer ch, input logic [1:0] r,
                                  input logic [1:0] d);
    logic [3:0] fs, wl;  // [0] is the first bit of the field on the wire
    case (eff_rate(
        r
    ))
      1: fs = 4'b0000;  // 44.1 kHz: 0000
      2: fs = 4'b0011;  // 32 kHz:   1100 (bits 24, 25)
      default: fs = 4'b0010;  // 48 kHz: 0100 (bit 25)
    endcase
    case (eff_depth(
        d
    ))
      1: wl = 4'b1010;  // max 20 bits, 101 = 20 bits
      2: wl = 4'b1011;  // max 24 bits, 101 = 24 bits
      default: wl = 4'b0010;  // max 20 bits, 100 = 16 bits
    endcase
    if (k == 2) return 1'b1;
    if (k >= 20 && k <= 23) return (k - 20) == (ch - 1);
    if (k >= 24 && k <= 27) return fs[k-24];
    if (k >= 32 && k <= 35) return wl[k-32];
    return 1'b0;
  endfunction

  // CTA-861 Audio InfoFrame PB2: SF (Table 27) in [4:2], SS (Table 28) in [1:0].
  function automatic logic [7:0] ref_aif_pb2(input logic [1:0] r, input logic [1:0] d);
    logic [2:0] sf;
    logic [1:0] ss;
    case (eff_rate(
        r
    ))
      1: sf = 3'b010;
      2: sf = 3'b001;
      default: sf = 3'b011;
    endcase
    case (eff_depth(
        d
    ))
      1: ss = 2'b10;
      2: ss = 2'b11;
      default: ss = 2'b01;
    endcase
    return {3'b000, sf, ss};
  endfunction

  function automatic logic [7:0] pb(input integer k);  // InfoFrame byte k (0 = checksum)
    return subs[8*k+:8];
  endfunction

  function automatic logic [7:0] frame_sum(input integer len);
    logic [7:0] s;
    s = header[7:0] + header[15:8] + header[23:16];
    for (int k = 0; k <= len; k++) s += pb(k);
    return s;
  endfunction

  // ---- scoreboard of latched samples ---------------------------------------------
  logic [31:0] sq[$];  // {l, r} in the order the source latched them
  always @(posedge clk) if (rst_n && dut.audio_en) sq.push_back({audio_l, audio_r});
  // New sample values every clock; every bit moves.
  integer step = 0;
  always @(negedge clk) begin
    step++;
    audio_l <= 16'(step * 40503);
    audio_r <= 16'(~(step * 26557)) ^ 16'h5A3C;
  end

  // ---- the island schedule -----------------------------------------------------
  integer npk = 4;  // packet windows per line
  integer idle = 120;  // idle pixels per line
  integer field_lines = 4;
  logic   islands_on = 1'b1;
  integer w = -1;  // pixel within the island run, -1 = idle
  integer px = 0;
  integer line = 0;
  logic   line_islands = 1'b1;  // islands_on, sampled once per line
  // counter is hdmi_packet's: it counts island pixels, so it reads 0..31 in
  // each window and, the island being whole windows, 0 between islands.
  always @(posedge clk) begin
    if (!rst_n) begin
      packet_enable   <= 1'b0;
      counter         <= 5'd0;
      video_field_end <= 1'b0;
      px           = 0;
      line         = 0;
      line_islands = islands_on;
    end else begin
      video_field_end <= 1'b0;
      packet_enable   <= 1'b0;
      px++;
      if (px == idle + 32 * npk) begin
        px = 0;
        line++;
        line_islands = islands_on;
        if (line % field_lines == 0) video_field_end <= 1'b1;
      end
      w = (px >= idle && line_islands) ? px - idle : -1;
      packet_enable <= (w >= 0) && (w % 32 == 0);
      counter       <= (w >= 0) ? 5'(w % 32) : 5'd0;
    end
  end

  // ---- packet checks ----------------------------------------------------------
  integer errors = 0;
  integer n_aud = 0, n_acr = 0, n_avi = 0, n_aif = 0, n_spd = 0, n_gcp = 0, n_null = 0;
  integer aud_pkts = 0;  // audio packets since reset (IEC frame position)
  integer dropped = 0;
  logic allow_drop = 1'b0;
  integer acr_seen = 0;  // ACR packets since the last configuration change
  integer field_seen[8];  // types seen in this field
  integer avi_vics_checked = 0;
  logic [255:0] vic_seen = '0;

  task automatic fail(input string msg);
    if (errors < 25) $display("tb_audio_src: FAIL %s", msg);
    errors++;
  endtask

  task automatic check_audio;
    logic [55:0] sp;
    logic [31:0] got;
    integer f;
    if (header[15:8] !== 8'h0F) fail($sformatf("audio HB1 = %02h, want 0F", header[15:8]));
    if (header[19:16] !== 4'h0) fail($sformatf("audio sample_flat = %h", header[19:16]));
    for (int i = 0; i < 4; i++) begin
      f  = (4 * aud_pkts + i) % 192;
      sp = subs[56*i+:56];
      if (header[20+i] !== (f == 0))
        fail($sformatf("audio B flag %0d = %b at frame %0d", i, header[20+i], f));
      if (^{sp[51:48], sp[23:0]} !== 1'b0) fail("left subframe parity");
      if (^{sp[55:52], sp[47:24]} !== 1'b0) fail("right subframe parity");
      if (sp[50] !== ref_cs(f, 1, aud_rate, aud_depth))
        fail($sformatf(
             "left channel-status bit %0d = %b (rate %0d depth %0d)", f, sp[50], aud_rate, aud_depth
             ));
      if (sp[54] !== ref_cs(f, 2, aud_rate, aud_depth))
        fail($sformatf("right channel-status bit %0d = %b", f, sp[54]));
      if (sp[7:0] !== 8'd0 || sp[31:24] !== 8'd0) fail("16-bit sample not left-aligned");
      if (sp[49] !== 1'b0 || sp[48] !== 1'b0 || sp[53] !== 1'b0 || sp[52] !== 1'b0)
        fail("user or validity bit set");
    end
    // The four samples are the next four latched, or (after an overflow) a
    // later group of four, never a mix.
    begin
      integer skip;
      logic   ok;
      skip = 0;
      ok   = 1'b0;
      while (!ok && sq.size() >= 4 + skip) begin
        ok = 1'b1;
        for (int i = 0; i < 4; i++) begin
          sp  = subs[56*i+:56];
          got = {sp[23:8], sp[47:32]};
          if (got !== sq[skip+i]) ok = 1'b0;
        end
        if (!ok) skip += 4;
      end
      if (!ok)
        fail($sformatf("audio packet %0d carries samples never latched in that order", aud_pkts));
      else if (skip != 0 && !allow_drop)
        fail($sformatf("audio packet %0d skipped %0d samples without an overflow", aud_pkts, skip));
      else begin
        dropped += skip / 4;
        repeat (skip + 4) void'(sq.pop_front());
      end
    end
    aud_pkts++;
  endtask

  task automatic check_acr;
    integer n, cts;
    real want;
    for (int i = 0; i < 4; i++) begin
      // SB1-SB3 = CTS[19:16], [15:8], [7:0]; SB4-SB6 = N[19:16], [15:8], [7:0].
      n   = {subs[56*i+32+:4], subs[56*i+40+:8], subs[56*i+48+:8]};
      cts = {subs[56*i+8+:4], subs[56*i+16+:8], subs[56*i+24+:8]};
      if (n != ref_n(aud_rate)) fail($sformatf("ACR N = %0d, want %0d", n, ref_n(aud_rate)));
      // The first ACR after a change measures from the change; check the rest.
      if (acr_seen >= 1) begin
        want = (ref_n(aud_rate) / 128) * (div_max + div_frac / 256.0);
        if (cts < want - 1.0 || cts > want + 1.0)
          fail($sformatf(
               "ACR CTS = %0d, want %0.2f (div %0d + %0d/256)", cts, want, div_max, div_frac));
      end
      if (subs[56*i+:8] !== 8'd0) fail("ACR SB0 not zero");
    end
    if (header !== 24'h000001) fail($sformatf("ACR header %06h", header));
    acr_seen++;
  endtask

  task automatic check_aif;
    if (header !== {8'd10, 8'd1, 8'h84}) fail($sformatf("AIF header %06h", header));
    if (pb(1) !== 8'h01) fail($sformatf("AIF PB1 = %02h", pb(1)));
    if (pb(2) !== ref_aif_pb2(aud_rate, aud_depth))
      fail($sformatf(
           "AIF PB2 = %02h, want %02h (rate %0d depth %0d)",
           pb(
               2
           ),
           ref_aif_pb2(
               aud_rate, aud_depth
           ),
           aud_rate,
           aud_depth
           ));
    if (frame_sum(10) !== 8'd0) fail("AIF checksum");
  endtask

  task automatic check_avi;
    if (header !== {8'd13, 8'd2, 8'h82}) fail($sformatf("AVI header %06h", header));
    if (pb(1) !== 8'h00) fail($sformatf("AVI PB1 = %02h", pb(1)));
    if (pb(2) !== {2'b00, ref_aspect(vic), 4'b1000})
      fail($sformatf(
           "AVI PB2 = %02h for VIC %0d, want %02h", pb(2), vic, {2'b00, ref_aspect(vic), 4'b1000}));
    if (pb(3) !== 8'h88) fail($sformatf("AVI PB3 = %02h", pb(3)));
    if (pb(4) !== vic) fail($sformatf("AVI PB4 = %0d, want VIC %0d", pb(4), vic));
    if (frame_sum(13) !== 8'd0) fail("AVI checksum");
    avi_vics_checked++;
    vic_seen[vic] = 1'b1;
  endtask

  // Read each packet on the third pixel of its window: packet_type is latched on
  // the window's first pixel and the content follows it. The #1 puts the read
  // after the schedule block has advanced w on this edge.
  always @(posedge clk) begin
    #1;
    if (rst_n && w >= 0 && w % 32 == 2) begin
      case (header[7:0])
        8'h02: begin
          n_aud++;
          check_audio();
        end
        8'h01: begin
          n_acr++;
          check_acr();
        end
        8'h84: begin
          n_aif++;
          field_seen[4]++;
          check_aif();
        end
        8'h82: begin
          n_avi++;
          field_seen[3]++;
          check_avi();
        end
        8'h83: begin
          n_spd++;
          field_seen[5]++;
          if (header !== {8'd25, 8'd1, 8'h83}) fail($sformatf("SPD header %06h", header));
          if (frame_sum(25) !== 8'd0) fail("SPD checksum");
        end
        8'h03: begin
          n_gcp++;
          field_seen[6]++;
          if (header !== 24'h000003 || subs !== 224'd0) fail("GCP not all zero");
        end
        8'h00: begin
          n_null++;
          if (header !== 24'd0 || subs !== 224'd0) fail("Null packet not all zero");
          // Null only once everything due this field has gone out.
          if (field_seen[3] == 0 || field_seen[4] == 0 || field_seen[5] == 0 || field_seen[6] == 0)
            fail("Null sent while an InfoFrame or the GCP was still due");
        end
        default: fail($sformatf("unknown packet type %02h", header[7:0]));
      endcase
    end
  end
  always @(posedge clk) begin
    if (video_field_end || !rst_n) begin
      for (int t = 3; t <= 6; t++) begin
        if (rst_n && field_seen[t] > 1)
          fail($sformatf("packet type %0d sent %0d times in one field", t, field_seen[t]));
      end
      for (int t = 0; t < 8; t++) field_seen[t] = 0;
    end
  end

  // ---- phases --------------------------------------------------------------------
  task automatic configure(input logic [1:0] r, input logic [1:0] d, input logic [12:0] mx,
                           input logic [7:0] fr);
    // A rate or mode change happens with the pixel domain in reset.
    @(negedge clk);
    rst_n     = 1'b0;
    aud_rate  = r;
    aud_depth = d;
    div_max   = mx;
    div_frac  = fr;
    repeat (4) @(negedge clk);
    sq.delete();
    aud_pkts = 0;
    acr_seen = 0;
    rst_n    = 1'b1;
  endtask

  task automatic run_until_acr(input integer n_acrs, input integer limit);
    integer t;
    t = 0;
    while (acr_seen < n_acrs && t < limit) begin
      @(posedge clk);
      t++;
    end
    if (acr_seen < n_acrs) fail($sformatf("only %0d ACR packets in %0d clocks", acr_seen, t));
  endtask

  initial begin
    for (int t = 0; t < 8; t++) field_seen[t] = 0;
    // Rates x depths x dividers.
    configure(2'd0, 2'd0, 13'd40, 8'd0);
    run_until_acr(3, 40000);
    configure(2'd1, 2'd1, 13'd57, 8'd128);
    run_until_acr(3, 40000);
    configure(2'd2, 2'd2, 13'd70, 8'd255);
    run_until_acr(3, 40000);
    configure(2'd3, 2'd3, 13'd45, 8'd17);
    run_until_acr(3, 40000);
    configure(2'd0, 2'd1, 13'd33, 8'd200);
    run_until_acr(3, 40000);
    configure(2'd1, 2'd2, 13'd41, 8'd3);
    run_until_acr(3, 40000);
    configure(2'd2, 2'd0, 13'd38, 8'd96);
    run_until_acr(3, 40000);
    // The divider's widest values: every input bit, both ways.
    configure(2'd0, 2'd0, 13'h1FFF, 8'hFF);
    repeat (20000) @(posedge clk);
    configure(2'd0, 2'd0, 13'h0AAA, 8'h55);
    repeat (6000) @(posedge clk);
    configure(2'd0, 2'd0, 13'h1555, 8'hAA);
    repeat (12000) @(posedge clk);
    // The longest ACR period, 44.1 kHz at the widest divider (CTS 0x61FFF),
    // then one whose CTS (0x0D000) sets the CTS bits that one leaves clear.
    configure(2'd1, 2'd0, 13'h1FFF, 8'hFF);
    run_until_acr(2, 900000);
    configure(2'd0, 2'd0, 13'h0455, 8'h55);
    run_until_acr(2, 120000);

    // Every VIC: one per line, a field per line so the AVI InfoFrame repeats.
    configure(2'd0, 2'd0, 13'd40, 8'd0);
    field_lines = 1;
    npk         = 6;
    for (int v = 0; v < 256; v++) begin
      vic = 8'(v);
      @(posedge video_field_end);
    end
    repeat (400) @(posedge clk);
    vic         = 8'd4;
    field_lines = 4;
    npk         = 4;

    // FIFO overflow: withhold the islands until whole groups must be dropped.
    configure(2'd0, 2'd0, 13'd40, 8'd0);
    run_until_acr(2, 40000);
    allow_drop = 1'b1;
    islands_on = 1'b0;
    repeat (3000) @(posedge clk);
    if (!dut.fifo_full) fail("the sample FIFO never filled");
    islands_on = 1'b1;
    run_until_acr(6, 60000);
    allow_drop = 1'b0;
    if (dropped == 0) fail("no group was dropped on overflow");

    // A reset in mid-stream, then a clean run.
    repeat (777) @(posedge clk);
    configure(2'd1, 2'd0, 13'd44, 8'd64);
    run_until_acr(3, 40000);

    if (errors == 0 && n_aud > 300 && n_acr > 30 && &vic_seen && n_aif > 20 &&
        n_spd > 20 && n_gcp > 20 && n_null > 20)
      $display(
          "tb_audio_src: PASS (%0d audio, %0d ACR, %0d AVI over VIC 0-255, %0d AIF, %0d SPD, %0d GCP, %0d Null packets; %0d groups dropped on overflow)",
          n_aud,
          n_acr,
          n_avi,
          n_aif,
          n_spd,
          n_gcp,
          n_null,
          dropped
      );
    else begin
      $display(
          "tb_audio_src: FAIL %0d error(s); audio %0d ACR %0d AVI %0d (all VICs %b) AIF %0d SPD %0d GCP %0d Null %0d",
          errors, n_aud, n_acr, n_avi, &vic_seen, n_aif, n_spd, n_gcp, n_null);
      $fatal(1);
    end
    $finish;
  end

endmodule

`default_nettype wire

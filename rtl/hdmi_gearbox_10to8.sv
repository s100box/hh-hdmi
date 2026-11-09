// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// hdmi_gearbox_10to8.sv -- TMDS symbols (10 bits a pixel clock) to bytes (8
// bits a word clock) for an 8:1 serializer, LANES lanes at once, with a
// crossing the router does not have to win.
//
//   clk_pix  (F)      one 10-bit symbol per lane per cycle
//   clk_word (F*5/4)  one byte per lane per cycle, bit 0 first on the wire
//
// The two clocks must be phase-locked (one PLL or MMCM, or one fed from the
// other), so 4 pixel periods are exactly 5 word periods. Unlike the gearbox
// inside hdmi_serializer_us, which copies its group register into the word
// domain on every word clock and so must close on the tightest edge pair
// (1/(5F), 1.347 ns at 1080p's 148.5 MHz), this one double-buffers:
//
// - The pixel side collects four symbols per lane and writes the 40-bit
//   group into one of two buffers, alternately, and flips grp_tgl. Each
//   buffer then holds still for 8 pixel periods (10 word periods).
// - The word side brings grp_tgl through a two-flop synchronizer (an
//   asynchronous crossing: tgl_meta is constrained as one). On the first
//   flip it sees after rst_word_n it aligns: it loads the buffer just
//   written on the next clock, and from then on every fifth clock, by its
//   own count. That load comes between 2 and 4 word periods after the
//   buffer's write and 6 before its next, so the buffer-to-word-register
//   paths are a multicycle crossing: the consumer constrains every path
//   from buf0/buf1 into sh/word_o as 2 word periods for setup, 1 for hold.
// - After alignment the synchronized flips must keep arriving on the same
//   count, give or take the synchronizer's one clock; one that does not,
//   or none at all while the word clock keeps running, clears aligned and
//   sets sticky slip; the next flip re-aligns. A stopped word clock cannot
//   report a fault, and whole lost toggle periods can be unobservable.
//
// Until aligned the bytes are zero. Resets are synchronous, active low, in
// each domain; either release order is supported after a common assertion.
// Reset both domains after PLL/clock changes before qualifying new output.
//----------------------------------------------------------------------------
`default_nettype none

module hdmi_gearbox_10to8 #(
    parameter int unsigned LANES = 4
) (
    input  wire logic                clk_pix,
    input  wire logic                rst_pix_n,
    input  wire logic [10*LANES-1:0] sym_i,       // lane l in [10l +: 10]
    input  wire logic                clk_word,
    input  wire logic                rst_word_n,
    output logic      [ 8*LANES-1:0] word_o,      // lane l in [8l +: 8], bit 0 first
    output logic                     aligned_o,   // clk_word
    output logic                     slip_o       // clk_word, sticky until rst_word_n
);

  // ---- pixel side ------------------------------------------------------------
  logic [         1:0] n;
  logic [30*LANES-1:0] acc;
  logic [40*LANES-1:0] buf0, buf1;
  logic wsel, grp_tgl;

  always_ff @(posedge clk_pix) begin
    if (!rst_pix_n) begin
      n       <= 2'd0;
      wsel    <= 1'b0;
      grp_tgl <= 1'b0;
    end else begin
      n <= n + 2'd1;
      for (int l = 0; l < LANES; l++) begin
        if (n != 2'd3) acc[30*l+10*n+:10] <= sym_i[10*l+:10];
      end
      if (n == 2'd3) begin
        for (int l = 0; l < LANES; l++) begin
          if (wsel) buf1[40*l+:40] <= {sym_i[10*l+:10], acc[30*l+:30]};
          else buf0[40*l+:40] <= {sym_i[10*l+:10], acc[30*l+:30]};
        end
        wsel    <= !wsel;
        grp_tgl <= !grp_tgl;  // after the flip it names the next buffer
      end
    end
  end

  // ---- word side -------------------------------------------------------------
  (* ASYNC_REG = "TRUE" *) logic tgl_meta, tgl_sync;
  logic                tgl_prev;
  logic [         2:0] cnt;  // 0 is a load
  logic                rsel;
  logic                seen;  // this group's flip arrived (cnt 3, 4 or 0)
  logic [32*LANES-1:0] sh;
  wire                 flip = (tgl_sync != tgl_prev);

  always_ff @(posedge clk_word) begin
    tgl_meta <= grp_tgl;
    tgl_sync <= tgl_meta;
    tgl_prev <= tgl_sync;
    if (!rst_word_n) begin
      aligned_o <= 1'b0;
      slip_o    <= 1'b0;
      cnt       <= 3'd0;
      rsel      <= 1'b0;
      seen      <= 1'b0;
      word_o    <= '0;
      sh        <= '0;
    end else begin
      cnt <= (cnt == 3'd4) ? 3'd0 : cnt + 3'd1;
      if (!aligned_o) begin
        word_o <= '0;
        if (flip) begin
          // the buffer just written is the one grp_tgl no longer names; it
          // loads on the next clock (cnt 0)
          aligned_o <= 1'b1;
          cnt       <= 3'd0;
          rsel      <= !tgl_sync;
          seen      <= 1'b1;
        end
      end else begin
        if (cnt == 3'd0) begin
          for (int l = 0; l < LANES; l++) begin
            word_o[8*l+:8] <= rsel ? buf1[40*l+:8] : buf0[40*l+:8];
            sh[32*l+:32]   <= rsel ? buf1[40*l+8+:32] : buf0[40*l+8+:32];
          end
          rsel <= !rsel;
        end else begin
          for (int l = 0; l < LANES; l++) begin
            word_o[8*l+:8] <= sh[32*l+:8];
            sh[32*l+:32]   <= {8'h00, sh[32*l+8+:24]};
          end
        end
        // a flip belongs on the clock before a load (cnt 4), or one clock
        // either side of it through the synchronizer
        if (flip) seen <= 1'b1;
        if (cnt == 3'd1) seen <= flip;
        if ((flip && cnt != 3'd4 && cnt != 3'd3 && cnt != 3'd0) || (cnt == 3'd1 && !seen)) begin
          aligned_o <= 1'b0;
          slip_o    <= 1'b1;
        end
      end
    end
  end

endmodule

`default_nettype wire

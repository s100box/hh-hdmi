// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// hdmi_serializer_us.sv -- 10:1 TMDS serializer for Xilinx UltraScale /
// UltraScale+.
//
// The UltraScale OSERDESE3 has no master/slave cascade, so it cannot take a
// 10-bit word the way the 7-series OSERDESE2 pair in hdmi_serializer.sv does.
// It serializes 8 bits per CLKDIV cycle (DATA_WIDTH 8, DDR on CLK). This
// module therefore puts a 10-to-8 gearbox in front of it:
//
//   clk_pix  (F)      one 10-bit TMDS symbol per cycle
//   clk_word (F*5/4)  one 8-bit word per cycle into the OSERDESE3 (CLKDIV)
//   clk_bit  (F*5)    OSERDESE3 CLK, two bits per cycle
//
// All three must come from integer dividers of one MMCM VCO (e.g. VCO =
// 20F: pixel /20, word /16, bit /4), so they are phase-locked with rising
// edges coinciding every 4 pixel = 5 word = 20 bit periods.
//
// Gearbox. The pixel side collects four symbols into a 40-bit group and, in
// the same clock edge, flips grp_tgl. The word side copies grp and grp_tgl
// into its own registers every clk_word cycle (flop-to-flop, no logic), and
// when the copied toggle changes it loads the group and emits it as five
// bytes, bits [7:0] first. A group arrives exactly every 5 word cycles, so
// the output is continuous: no symbol is dropped or repeated. The word side
// locks on the first group it sees after rst_word_n; until then it sends
// zeros. Symbol order on the wire is LSB first, symbol after symbol.
//
// Cadence check: once aligned, a group arriving at any cycle other than
// the fifth, or no group by the fifth, clears `aligned` and sets the sticky
// `slip` (cleared only by rst_word_n). An early group re-aligns on itself;
// a missing one sends zeros until the next group. Neither can happen while
// the clocks are locked and rst_pix_n stays high, so `slip` is a fault
// report, not a normal event.
//
// Timing. The only clk_pix -> clk_word paths are grp[39:0] and grp_tgl, each
// straight into one clk_word flop. The clocks are related (one MMCM), so
// Vivado times these paths natively; the tightest edge pair is 4 VCO
// periods = 1/(5F) (2.694 ns at F = 74.25 MHz). Do not cut them with
// set_false_path / set_clock_groups -asynchronous and do not mark them
// ASYNC_REG: the gearbox is correct only because every capture is timed.
// No clk_word -> clk_pix path exists. The OSERDESE3 CLK/CLKDIV relationship
// is checked by Vivado's own OSERDESE3 timing arcs.
//
// Resets: rst_pix_n (clk_pix) and rst_word_n (clk_word), synchronous,
// active low, released after the MMCM locks. Release order does not
// matter; if the word side is out of reset first, the first symbol after
// rst_pix_n is the first one on the wire. rst_word_n also resets the
// OSERDESE3.
//
// Vendor selection (compile time, like hdmi_serializer.sv):
//   PLL_SIM_FREE_RUN  -> generic model (overrides everything)
//   VENDOR_XILINX_US  -> OSERDESE3 (D[0] is the first bit out)
//   otherwise         -> generic model: a clk_bit DDR shift register that
//                        loads each clk_word word. Simulation only.
// The differential output buffer (OBUFDS) stays at the board top.
//----------------------------------------------------------------------------
`default_nettype none

module hdmi_serializer_us (
    input wire logic       clk_pix,
    input wire logic       rst_pix_n,
    input wire logic [9:0] parallel,   // TMDS symbol, bit 0 sent first

    input wire logic clk_word,    // clk_pix * 5/4, same MMCM
    input wire logic rst_word_n,
    input wire logic clk_bit,     // clk_pix * 5,   same MMCM (DDR)

    output logic serial,   // to the board top's OBUFDS
    output logic aligned,  // clk_word: gearbox locked to the groups
    output logic slip      // clk_word: sticky cadence fault
);

  // ---- clk_pix: assemble four symbols into one group ----------------------
  logic [ 1:0] pcnt;
  logic [29:0] acc;
  logic [39:0] grp;  // symbols {3,2,1,0}; crosses to clk_word
  logic        grp_tgl;  // flips with every new grp; crosses to clk_word

  always_ff @(posedge clk_pix) begin
    if (!rst_pix_n) begin
      pcnt    <= 2'd0;
      grp_tgl <= 1'b0;
    end else begin
      pcnt <= pcnt + 2'd1;
      case (pcnt)
        2'd0: acc[9:0] <= parallel;
        2'd1: acc[19:10] <= parallel;
        2'd2: acc[29:20] <= parallel;
        default: begin
          grp     <= {parallel, acc};
          grp_tgl <= ~grp_tgl;
        end
      endcase
    end
  end

  // ---- clk_word: capture (flop to flop), then detect a new group ----------
  // grp_w and tgl_w sample the pixel-side registers on the same edge, so they
  // always hold the same group. No reset: they only mirror clk_pix flops.
  logic [39:0] grp_w;
  logic tgl_w, tgl_wd;
  always_ff @(posedge clk_word) begin
    grp_w  <= grp;
    tgl_w  <= grp_tgl;
    tgl_wd <= tgl_w;
  end
  wire         arrive = tgl_w ^ tgl_wd;  // grp_w holds a group not yet taken

  // ph counts the bytes of the current group already scheduled: the load
  // cycle sends byte 0 and sets ph = 1; bytes 1..4 follow; the next group
  // must arrive when ph == 5.
  logic [ 2:0] ph;
  logic [31:0] sh;  // bytes 1..4 still to send
  logic [ 7:0] word;  // to the OSERDESE3 D[7:0]

  always_ff @(posedge clk_word) begin
    if (!rst_word_n) begin
      ph      <= 3'd0;
      sh      <= 32'd0;
      word    <= 8'd0;
      aligned <= 1'b0;
      slip    <= 1'b0;
    end else begin
      if (arrive) begin
        // Load: byte 0 now, the rest from sh.
        word    <= grp_w[7:0];
        sh      <= grp_w[39:8];
        ph      <= 3'd1;
        aligned <= 1'b1;
        if (aligned && ph != 3'd5) slip <= 1'b1;  // early group
      end else if (aligned && ph == 3'd5) begin
        // The group due now did not come: send idle until the next one.
        word    <= 8'd0;
        ph      <= 3'd0;
        aligned <= 1'b0;
        slip    <= 1'b1;
      end else if (aligned) begin
        word <= sh[7:0];
        sh   <= {8'd0, sh[31:8]};
        ph   <= ph + 3'd1;
      end else begin
        word <= 8'd0;
      end
    end
  end

`ifndef PLL_SIM_FREE_RUN
`ifdef VENDOR_XILINX_US
  `define HDMI_SER_US_OSERDESE3
`endif
`endif

`ifdef HDMI_SER_US_OSERDESE3
  // ---- UltraScale / UltraScale+ OSERDESE3, 8:1 DDR ------------------------
  // CLK = clk_bit, CLKDIV = clk_word (CLK/4). D[0] leaves first. The 3-state
  // path is unused (T tied low, T_OUT open): a TMDS lane always drives.
  OSERDESE3 #(
      .DATA_WIDTH        (8),
      .INIT              (1'b0),
      .IS_CLKDIV_INVERTED(1'b0),
      .IS_CLK_INVERTED   (1'b0),
      .IS_RST_INVERTED   (1'b0),
      .SIM_DEVICE        ("ULTRASCALE_PLUS")
  ) u_oserdes (
      .OQ    (serial),
      .T_OUT (),
      .CLK   (clk_bit),
      .CLKDIV(clk_word),
      .D     (word),
      .RST   (~rst_word_n),
      .T     (1'b0)
  );
`else
  // ---- Generic model (simulation only) -------------------------------------
  // hold/wtg are written on clk_word; the clk_bit side notices the new word
  // one clk_bit edge later (wtg != wtg_b) and shifts it out two bits per
  // clk_bit cycle, D[0] first: the rising-edge half carries the even bit.
  logic [7:0] hold, cur;
  logic wtg, wtg_b;
  logic [1:0] k;
  logic ser_p, ser_n, nxt_n;

  always_ff @(posedge clk_word) begin
    if (!rst_word_n) wtg <= 1'b0;
    else wtg <= ~wtg;
    hold <= word;
  end

  always_ff @(posedge clk_bit) begin
    wtg_b <= wtg;
    if (!rst_word_n) begin
      k     <= 2'd0;
      cur   <= 8'd0;
      ser_p <= 1'b0;
      nxt_n <= 1'b0;
    end else if (wtg != wtg_b) begin
      cur   <= hold;
      k     <= 2'd1;
      ser_p <= hold[0];
      nxt_n <= hold[1];
    end else begin
      k     <= k + 2'd1;
      ser_p <= cur[{k, 1'b0}];
      nxt_n <= cur[{k, 1'b1}];
    end
  end

  always_ff @(negedge clk_bit) ser_n <= nxt_n;

  assign serial = clk_bit ? ser_p : ser_n;
`endif

`ifdef HDMI_SER_US_OSERDESE3
  `undef HDMI_SER_US_OSERDESE3
`endif

endmodule

`default_nettype wire

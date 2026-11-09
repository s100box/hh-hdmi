// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
// hdmi_serializer.sv
//
// 10:1 serializer for TMDS lanes. Wraps the vendor SERDES primitive so the rest
// of the design stays vendor-neutral: Gowin OSER10 by default, the Xilinx
// 7-series OSERDESE2 master/slave pair under `VENDOR_XILINX`.
//
// Inputs:
//   clk_pix    -- pixel clock (e.g. 74.25 MHz for 1280x720p60)
//   clk_pix_5x -- 5x pixel clock. The serializer uses both edges of clk_pix_5x
//                to emit 2 bits per cycle = 10 bits per pixel-clock cycle.
//   parallel   -- 10-bit symbol from the TMDS encoder (LSB-first wire order)
//
// Output:
//   serial     -- single-ended serial line; the board top's differential output
//                buffer (Gowin TLVDS_OBUF/ELVDS_OBUF, Xilinx OBUFDS) converts
//                this to a TMDS pair.

`default_nettype none

module hdmi_serializer (
    input  wire logic       clk_pix,
    input  wire logic       clk_pix_5x,
    input  wire logic       reset_n,
    input  wire logic [9:0] parallel,
    output logic            serial
);
  // Compile-time selection: PLL_SIM_FREE_RUN picks the generic shift-register
  // model below for a simulation that has no vendor primitive library;
  // VENDOR_XILINX (from the board's defines) picks the OSERDESE2 pair; otherwise
  // the Gowin OSER10 (synthesis, or a simulation that loads Gowin's prim_sim.v).
`ifdef PLL_SIM_FREE_RUN
  `define _HDMI_SER_GENERIC
`elsif VENDOR_XILINX
  `define _HDMI_SER_OSERDESE2
`else
  `define _HDMI_SER_OSER10
`endif

`ifdef _HDMI_SER_OSER10
  // ---- Gowin OSER10 (the same primitive on GW2A and GW5A) ----
  OSER10 u_oser10 (
      .Q    (serial),
      .D0   (parallel[0]),
      .D1   (parallel[1]),
      .D2   (parallel[2]),
      .D3   (parallel[3]),
      .D4   (parallel[4]),
      .D5   (parallel[5]),
      .D6   (parallel[6]),
      .D7   (parallel[7]),
      .D8   (parallel[8]),
      .D9   (parallel[9]),
      .PCLK (clk_pix),
      .FCLK (clk_pix_5x),
      .RESET(~reset_n)
  );
`elsif _HDMI_SER_OSERDESE2
  // ---- Xilinx 7-series OSERDESE2 pair (10:1 DDR needs master + slave) ----
  // A single OSERDESE2 serializes at most 8:1; widths above that cascade a
  // SLAVE into the MASTER's SHIFTIN1/2, and the last two bits enter the slave
  // on its D3/D4. CLK is the 5x TMDS clock, CLKDIV the pixel clock -- both taps
  // of the same MMCM, so they stay phase-related. Bit order: OSERDESE2 emits D1
  // first, so D1..D8 carry parallel[0..7] and the slave's D3/D4 carry [8]/[9].
  // RST is released synchronously to CLKDIV (the caller's reset already is).
  wire shift1, shift2;

  // DATA_RATE_TQ is SDR, not the DDR that mirrors DATA_RATE_OQ: the 3-state path
  // is unused here (T1..T4 tied low, TQ unconnected -- a TMDS lane always
  // drives), and DDR would oblige TRISTATE_WIDTH 4 to stay self-consistent,
  // which Vivado's AVAL-70 flags. SDR with width 1 says "no tristate" cleanly.
  OSERDESE2 #(
      .DATA_RATE_OQ  ("DDR"),
      .DATA_RATE_TQ  ("SDR"),
      .DATA_WIDTH    (10),
      .SERDES_MODE   ("MASTER"),
      .TRISTATE_WIDTH(1)
  ) u_oser_m (
      .OQ       (serial),
      .OFB      (),
      .SHIFTOUT1(),
      .SHIFTOUT2(),
      .TBYTEOUT (),
      .TFB      (),
      .TQ       (),
      .CLK      (clk_pix_5x),
      .CLKDIV   (clk_pix),
      .D1       (parallel[0]),
      .D2       (parallel[1]),
      .D3       (parallel[2]),
      .D4       (parallel[3]),
      .D5       (parallel[4]),
      .D6       (parallel[5]),
      .D7       (parallel[6]),
      .D8       (parallel[7]),
      .OCE      (1'b1),
      .RST      (~reset_n),
      .SHIFTIN1 (shift1),
      .SHIFTIN2 (shift2),
      .T1       (1'b0),
      .T2       (1'b0),
      .T3       (1'b0),
      .T4       (1'b0),
      .TBYTEIN  (1'b0),
      .TCE      (1'b0)
  );

  OSERDESE2 #(
      .DATA_RATE_OQ  ("DDR"),
      .DATA_RATE_TQ  ("SDR"),
      .DATA_WIDTH    (10),
      .SERDES_MODE   ("SLAVE"),
      .TRISTATE_WIDTH(1)
  ) u_oser_s (
      .OQ       (),
      .OFB      (),
      .SHIFTOUT1(shift1),
      .SHIFTOUT2(shift2),
      .TBYTEOUT (),
      .TFB      (),
      .TQ       (),
      .CLK      (clk_pix_5x),
      .CLKDIV   (clk_pix),
      .D1       (1'b0),
      .D2       (1'b0),
      .D3       (parallel[8]),
      .D4       (parallel[9]),
      .D5       (1'b0),
      .D6       (1'b0),
      .D7       (1'b0),
      .D8       (1'b0),
      .OCE      (1'b1),
      .RST      (~reset_n),
      .SHIFTIN1 (1'b0),
      .SHIFTIN2 (1'b0),
      .T1       (1'b0),
      .T2       (1'b0),
      .T3       (1'b0),
      .T4       (1'b0),
      .TBYTEIN  (1'b0),
      .TCE      (1'b0)
  );

`else
  // ---- Generic fallback (simulation / no vendor primitive library) ----
  // A shift register clocked at 5x loads each symbol once per pixel and sends
  // two bits per clk_pix_5x cycle, LSB first like OSER10 and OSERDESE2: each
  // rising edge stages one bit pair, the even bit for the high half and the odd
  // bit for the low half that follows. Adequate for simulation; not
  // timing-clean for real silicon.
  logic [9:0] shift_p;
  logic [2:0] cnt;

  always_ff @(posedge clk_pix_5x or negedge reset_n) begin
    if (!reset_n) begin
      cnt     <= 3'd0;
      shift_p <= 10'd0;
    end else begin
      if (cnt == 3'd0) shift_p <= parallel;
      else shift_p <= {2'b00, shift_p[9:2]};
      cnt <= (cnt == 3'd4) ? 3'd0 : cnt + 3'd1;
    end
  end

  // The odd bit is staged on the same rising edge as the even one, from the
  // same pair, and moves to serial_n on the falling edge.
  logic serial_p, serial_n, next_n;
  always_ff @(posedge clk_pix_5x) begin
    serial_p <= shift_p[0];
    next_n   <= shift_p[1];
  end
  always_ff @(negedge clk_pix_5x) serial_n <= next_n;

  // DDR output emulated as a mux on clk_pix_5x level
  assign serial = clk_pix_5x ? serial_p : serial_n;
`endif
endmodule

`default_nettype wire

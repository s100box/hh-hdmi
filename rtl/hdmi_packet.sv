// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// hdmi_packet.sv  --  HDMI data-island packet assembler + BCH ECC (HDMI 5.2.3).
//
// A data-island packet is 32 pixels long. Each pixel carries 9 bits: 1 header
// bit (lane 0) and 8 subpacket bits (lanes 1/2, two bits from each of the four
// 56-bit subpackets). This module sequences a packet's 24-bit header and four
// 56-bit subpackets out over the 32-pixel `counter`, computing the five BCH(8)
// parity bytes on the fly (one for the header, one per subpacket).
//
// `subs` is the four subpackets flattened: subs[i*56 +: 56] is subpacket i.
// The right-shifting BCH recurrence uses feedback mask 0x83. In the
// first-transmitted-bit-as-highest-power convention used by sim/tb_packet.sv,
// long division uses G(x) = x^8 + x^7 + x^6 + 1 (0x1C1).
//----------------------------------------------------------------------------
`default_nettype none

module hdmi_packet #(
    // DI_PIPE registers the packet content (header/subs) and delays the island
    // enable by one pixel, so the per-pixel BCH accumulate below runs from registers
    // instead of the long audio-parity + packet-type mux cone that produces `subs`.
    // This is the clk_pix critical path; pipelining it lets clk_pix close 150 MHz.
    // The counter + packet_data shift one pixel later; hdmi_encoder delays the rest
    // of the data-island datapath to match (DI_PIPE there), so the tmds output is
    // bit-identical with one added pixel of latency (verified by sim/tb_di_equiv).
    parameter bit DI_PIPE = 1'b0
) (
    input  wire logic         clk_pix,
    input  wire logic         rst_n,
    input  wire logic         data_island_period,
    input  wire logic [ 23:0] header,
    input  wire logic [223:0] subs,                // 4 x 56-bit subpackets
    output logic      [  8:0] packet_data,         // {2b x 4 subpackets, 1b header}
    output logic      [  4:0] counter              // 0..31 within the packet
);

  // Optional input pipeline: register the content and the enable together so the BCH
  // logic downstream sees a registered `subs_i`/`hdr_i` aligned to `dip_i`.
  logic [ 23:0] hdr_i;
  logic [223:0] subs_i;
  logic         dip_i;
  generate
    if (DI_PIPE) begin : g_pipe
      logic [ 23:0] hdr_q;
      logic [223:0] subs_q;
      logic         dip_q;
      always_ff @(posedge clk_pix) begin
        hdr_q  <= header;
        subs_q <= subs;
        dip_q  <= data_island_period;
      end
      assign hdr_i  = hdr_q;
      assign subs_i = subs_q;
      assign dip_i  = dip_q;
    end else begin : g_comb
      assign hdr_i  = header;
      assign subs_i = subs;
      assign dip_i  = data_island_period;
    end
  endgenerate

  // 32-pixel packet counter. `counter` is the module output that the audio source
  // uses to pace its scheduler, so it stays on the ORIGINAL (undelayed) enable. The
  // internal `bcnt` paces the BCH/packet_data below and tracks the registered
  // content: it runs on `dip_i`, so with DI_PIPE it is `counter` delayed one pixel
  // (and equal to `counter` when DI_PIPE=0). Keeping them separate leaves the audio
  // scheduler's timing untouched by the pipeline.
  logic [4:0] bcnt;
  always_ff @(posedge clk_pix) begin
    if (!rst_n) begin
      counter <= 5'd0;
      bcnt    <= 5'd0;
    end else begin
      if (data_island_period) counter <= counter + 5'd1;
      if (dip_i) bcnt <= bcnt + 5'd1;
    end
  end

  // Pre-decoded pixel position. Indexing subs_i by bcnt directly puts two chained
  // 56:1 muxes (select decode + tree) plus the ECC step between the bcnt register
  // and the parity registers -- the clk_pix critical path at 150+ MHz. Instead,
  // decode NEXT cycle's bcnt into a registered one-hot (bsel[j] <=> bcnt == j this
  // cycle), so every per-pixel bit selection below is a flat one-hot AND-OR from
  // registers. bcnt_next mirrors bcnt's D input exactly, so bsel is never stale.
  wire  [ 4:0] bcnt_next = !rst_n ? 5'd0 : (dip_i ? bcnt + 5'd1 : bcnt);
  logic [31:0] bsel;
  logic blt28, blt24;  // registered (bcnt < 28) / (bcnt < 24)
  always_ff @(posedge clk_pix) begin
    for (int j = 0; j < 32; j++) bsel[j] <= (bcnt_next == j[4:0]);
    blt28 <= (bcnt_next < 5'd28);
    blt24 <= (bcnt_next < 5'd24);
  end

  // Parity accumulators: [4] = header, [3:0] = the four subpackets.
  logic [7:0] parity[5];

  // One-hot selected data bits: per subpacket the even/odd bit of this pixel
  // (bits 2*bcnt / 2*bcnt+1, defined for bcnt < 28), and the header bit (bcnt < 24).
  // Out-of-range positions select 0; their consumers are guarded (blt28/blt24) or
  // covered by the parity terms in the packet_data mux below.
  logic [3:0] sub_e, sub_o;
  logic hdr_b;
  always_comb begin
    sub_e = 4'b0;
    sub_o = 4'b0;
    hdr_b = 1'b0;
    for (int k = 0; k < 4; k++) begin
      for (int j = 0; j < 28; j++) begin
        sub_e[k] |= bsel[j] & subs_i[k*56+2*j];
        sub_o[k] |= bsel[j] & subs_i[k*56+2*j+1];
      end
    end
    for (int j = 0; j < 24; j++) hdr_b |= bsel[j] & hdr_i[j];
  end

  // Each BCH block on the wire is {parity, data}: subpacket bits 56..63 and header
  // bits 24..31 are the parity bytes, sent during bcnt 28..31 / 24..31. Splice those
  // into the one-hot mux the same way.
  logic [8:0] pd;
  always_comb begin
    pd[0] = hdr_b;
    for (int k = 0; k < 4; k++) begin
      pd[1+k] = sub_e[k];  // packet_data[4:1] = even bits, subpackets 0..3
      pd[5+k] = sub_o[k];  // packet_data[8:5] = odd bits,  subpackets 0..3
      for (int j = 28; j < 32; j++) begin
        pd[1+k] |= bsel[j] & parity[k][2*(j-28)];
        pd[5+k] |= bsel[j] & parity[k][2*(j-28)+1];
      end
    end
    for (int j = 24; j < 32; j++) pd[0] |= bsel[j] & parity[4][j-24];
  end
  assign packet_data = pd;

  // One step of the systematic BCH(8) encoder (generator 0x83).
  function automatic logic [7:0] next_ecc(input logic [7:0] ecc, input logic bit_in);
    next_ecc = (ecc >> 1) ^ (((ecc[0] ^ bit_in) ? 8'h83 : 8'h00));
  endfunction

  // Subpackets feed two data bits per pixel; the header feeds one.
  wire [7:0] pnext0 = next_ecc(parity[0], sub_e[0]);
  wire [7:0] pnext1 = next_ecc(parity[1], sub_e[1]);
  wire [7:0] pnext2 = next_ecc(parity[2], sub_e[2]);
  wire [7:0] pnext3 = next_ecc(parity[3], sub_e[3]);
  wire [7:0] pnext4 = next_ecc(parity[4], hdr_b);
  wire [7:0] pnn0 = next_ecc(pnext0, sub_o[0]);
  wire [7:0] pnn1 = next_ecc(pnext1, sub_o[1]);
  wire [7:0] pnn2 = next_ecc(pnext2, sub_o[2]);
  wire [7:0] pnn3 = next_ecc(pnext3, sub_o[3]);

  always_ff @(posedge clk_pix) begin
    if (!rst_n || !dip_i) begin
      parity[0] <= 8'd0;
      parity[1] <= 8'd0;
      parity[2] <= 8'd0;
      parity[3] <= 8'd0;
      parity[4] <= 8'd0;
    end else begin
      if (blt28) begin  // subpackets: 56 bits = 28 pixels of 2 bits
        parity[0] <= pnn0;
        parity[1] <= pnn1;
        parity[2] <= pnn2;
        parity[3] <= pnn3;
        if (blt24) parity[4] <= pnext4;  // header: 24 bits, 1/pixel
      end else if (bsel[31]) begin
        parity[0] <= 8'd0;
        parity[1] <= 8'd0;
        parity[2] <= 8'd0;
        parity[3] <= 8'd0;
        parity[4] <= 8'd0;
      end
    end
  end

endmodule

`default_nettype wire

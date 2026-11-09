// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_packet.sv -- hdmi_packet against an independent model, DI_PIPE 0 and 1.
//
// Two instances share the stimulus: islands of one to four back-to-back
// packets with random headers and subpackets (plus all-zero and all-one
// packets), random content while the island is off, gaps of random length,
// and a reset that cuts an island mid-packet. Every pixel of every packet is
// checked:
//   * packet_data[0] is header bit j for pixels 0-23 and header ECC bit j-24
//     for pixels 24-31; packet_data[1+k]/[5+k] are subpacket k's bits 2j and
//     2j+1 for pixels 0-27 and its ECC bits 2(j-28) and 2(j-28)+1 after;
//   * the ECC bytes come from polynomial division by the HDMI generator
//     G(x) = 1 + x^6 + x^7 + x^8 (first bit sent = highest-order term), not
//     from the shift-register form the RTL uses;
//   * DI_PIPE = 1 gives the same packet_data one pixel later;
//   * counter, in both builds, counts island pixels mod 32 on the undelayed
//     enable.
//----------------------------------------------------------------------------
`default_nettype none

module tb_packet;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic rst_n = 1'b0;
  logic dip = 1'b0;
  logic [23:0] header = '0;
  logic [223:0] subs = '0;

  wire [8:0] pd0, pd1;
  wire [4:0] cnt0, cnt1;

  hdmi_packet #(
      .DI_PIPE(1'b0)
  ) p0 (
      .clk_pix           (clk),
      .rst_n             (rst_n),
      .data_island_period(dip),
      .header            (header),
      .subs              (subs),
      .packet_data       (pd0),
      .counter           (cnt0)
  );
  hdmi_packet #(
      .DI_PIPE(1'b1)
  ) p1 (
      .clk_pix           (clk),
      .rst_n             (rst_n),
      .data_island_period(dip),
      .header            (header),
      .subs              (subs),
      .packet_data       (pd1),
      .counter           (cnt1)
  );

  // Island pixels since reset, mod 32.
  logic [4:0] pix = '0;
  always @(posedge clk)
    if (!rst_n) pix <= '0;
    else if (dip) pix <= pix + 5'd1;

  integer errors = 0, packets = 0, pixels = 0;

  // ECC of the first n bits of d (bit 0 sent first): the remainder of
  // d(x) * x^8 mod G(x), the coefficient of x^k carried in ECC bit 7-k.
  function automatic logic [7:0] bch(input logic [55:0] d, input integer n);
    logic [63:0] m;
    m = '0;
    for (int i = 0; i < n; i++) if (d[i]) m[n-1-i+8] = 1'b1;
    for (int dg = n - 1 + 8; dg >= 8; dg--) if (m[dg]) m[dg-8+:9] = m[dg-8+:9] ^ 9'h1C1;
    for (int k = 0; k < 8; k++) bch[7-k] = m[k];
  endfunction

  // The current packet's ECC bytes, {subpackets 3..0, header}, computed once
  // per packet.
  logic [39:0] ecc = '0;

  function automatic logic [39:0] packet_ecc(input logic [23:0] h, input logic [223:0] s);
    packet_ecc[7:0] = bch({32'd0, h}, 24);
    for (int k = 0; k < 4; k++) packet_ecc[8+8*k+:8] = bch(s[k*56+:56], 56);
  endfunction

  function automatic logic [8:0] model(input logic [23:0] h, input logic [223:0] s,
                                       input logic [39:0] p, input logic [4:0] j);
    logic [ 7:0] hp;
    logic [55:0] sk;
    logic [ 7:0] sp;
    hp       = p[7:0];
    model[0] = (j < 24) ? h[j] : hp[j-24];
    for (int k = 0; k < 4; k++) begin
      sk         = s[k*56+:56];
      sp         = p[8+8*k+:8];
      model[1+k] = (j < 28) ? sk[2*j] : sp[2*(j-28)];
      model[5+k] = (j < 28) ? sk[2*j+1] : sp[2*(j-28)+1];
    end
  endfunction

  function automatic logic [223:0] rand_subs();
    for (int i = 0; i < 7; i++) rand_subs[i*32+:32] = $urandom;
  endfunction

  // Content for the next packet: 0 random, 1 all zeros, 2 all ones.
  integer kind = 0;

  logic [8:0] exp_prev = '0;
  logic exp_prev_v = 1'b0;

  // One pixel clock: drive at the falling edge, check both builds after it.
  task automatic cycle(input logic r, input logic d);
    logic [8:0] e;
    @(negedge clk);
    rst_n = r;
    dip   = d;
    if (!d) begin
      header = 24'($urandom);
      subs   = rand_subs();
    end else if (pix == 5'd0) begin
      header = (kind == 1) ? '0 : (kind == 2) ? '1 : 24'($urandom);
      subs   = (kind == 1) ? '0 : (kind == 2) ? '1 : rand_subs();
      ecc    = packet_ecc(header, subs);
      packets++;
    end
    #1;
    if (r && (cnt0 !== pix || cnt1 !== pix)) begin
      if (errors < 10) $display("FAIL: counter %0d / %0d, want %0d", cnt0, cnt1, pix);
      errors++;
    end
    e = d ? model(header, subs, ecc, pix) : 'x;
    if (r && d) begin
      pixels++;
      if (pd0 !== e) begin
        if (errors < 10)
          $display("FAIL: DI_PIPE=0 pixel %0d packet_data %03h, want %03h", pix, pd0, e);
        errors++;
      end
    end
    if (exp_prev_v && pd1 !== exp_prev) begin
      if (errors < 10)
        $display("FAIL: DI_PIPE=1 packet_data %03h, want %03h one pixel late", pd1, exp_prev);
      errors++;
    end
    exp_prev   = e;
    exp_prev_v = r && d;
  endtask

  task automatic island(input integer npk);
    for (int i = 0; i < 32 * npk; i++) cycle(1'b1, 1'b1);
  endtask

  task automatic gap(input integer n);
    for (int i = 0; i < n; i++) cycle(1'b1, 1'b0);
  endtask

  initial begin : run
    for (int i = 0; i < 4; i++) cycle(1'b0, 1'b0);
    gap(3);
    // All-zero and all-one packets, alone and back to back.
    kind = 1;
    island(1);
    gap(2);
    kind = 2;
    island(2);
    kind = 1;
    island(1);
    gap(1);
    kind = 0;
    for (int n = 0; n < 60; n++) begin
      island(1 + ($urandom % 4));
      gap(1 + ($urandom % 24));
    end
    // A one-clock reset that drops the island mid-packet; the next island
    // starts on the clock after it, at pixel 0.
    for (int i = 0; i < 13; i++) cycle(1'b1, 1'b1);
    cycle(1'b0, 1'b0);
    for (int n = 0; n < 10; n++) begin
      island(1 + ($urandom % 4));
      gap(1 + ($urandom % 24));
    end
    if (errors == 0 && packets > 150) begin
      $display("tb_packet: PASS (%0d packets, %0d pixels, DI_PIPE 0 and 1)", packets, pixels);
      $finish;
    end else $fatal(1, "tb_packet: FAIL (%0d errors, %0d packets)", errors, packets);
  end
endmodule

`default_nettype wire

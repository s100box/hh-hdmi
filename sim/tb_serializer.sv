// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_serializer.sv -- hdmi_serializer's generic model (compile with
// -DPLL_SIM_FREE_RUN), the 10:1 path a board on Gowin or 7-series takes.
//
// clk_pix_5x and clk_pix are phase-related (one rising edge of clk_pix every
// five of clk_pix_5x, coinciding), as the two taps of one PLL are. A register
// on clk_pix presents a new random symbol every pixel; the serial line is
// sampled in the middle of each half of clk_pix_5x, so every bit time is read
// once. The bench then finds the symbol stream in the bit stream and checks:
//
//   * every symbol appears, in order, LSB first, with none dropped or
//     repeated, from the first one after reset to the end of the run;
//   * that holds for each of the five phases at which reset_n can release
//     against clk_pix (the model's load point moves with it);
//   * an asynchronous reset in mid-stream drives the line low while it is
//     held, and the stream after its release is intact again.
//----------------------------------------------------------------------------
`default_nettype none

module tb_serializer;
  logic clk_pix_5x = 1'b0;
  logic clk_pix = 1'b0;
  always #1 clk_pix_5x = ~clk_pix_5x;
  always #5 clk_pix = ~clk_pix;

  logic       reset_n = 1'b0;
  logic [9:0] parallel = 10'd0;
  wire        serial;

  hdmi_serializer u_ser (
      .clk_pix   (clk_pix),
      .clk_pix_5x(clk_pix_5x),
      .reset_n   (reset_n),
      .parallel  (parallel),
      .serial    (serial)
  );

  // ---- stimulus and capture ----------------------------------------------------
  localparam int MAXS = 4096;
  logic [9:0] sent[      MAXS];
  logic       bits[10*MAXS+64];
  integer ns = 0, nb = 0;
  logic recording = 1'b0;

  always @(posedge clk_pix) begin
    if (recording && ns < MAXS) begin
      logic [9:0] s;
      s = 10'($urandom);
      parallel <= s;
      sent[ns] = s;
      ns++;
    end
  end
  // The middle of each half of clk_pix_5x: one sample per bit time.
  always @(clk_pix_5x) begin
    #0.5;
    if (recording && nb < 10 * MAXS + 64) begin
      bits[nb] = serial;
      nb++;
    end
  end

  integer errors = 0;
  integer total_checked = 0;

  function automatic logic [9:0] rx_sym(input integer o, input integer m);
    logic [9:0] v;
    for (int i = 0; i < 10; i++) v[i] = bits[o+10*m+i];
    return v;
  endfunction

  // Find symbol j0 (and the 23 after it) in the bit stream starting near ob0;
  // then check every later symbol up to j_end.
  task automatic check_from(input string name, input integer j0, input integer ob0,
                            input integer j_end);
    integer o, chk;
    o = -1;
    for (int ob = ob0; ob < ob0 + 200 && ob + 10 * 30 < nb && o < 0; ob++) begin
      bit ok;
      ok = 1;
      for (int m = 0; m < 24 && ok; m++) if (rx_sym(ob, m) !== sent[j0+m]) ok = 0;
      if (ok) o = ob;
    end
    if (o < 0) begin
      $display("tb_serializer: FAIL %s: symbol %0d never appears on the line", name, j0);
      errors++;
      return;
    end
    chk = 0;
    for (int m = 0; j0 + m < j_end && o + 10 * (m + 1) <= nb; m++) begin
      if (rx_sym(o, m) !== sent[j0+m]) begin
        $display("tb_serializer: FAIL %s: symbol %0d is %03h on the line, sent %03h", name, j0 + m,
                 rx_sym(o, m), sent[j0+m]);
        errors++;
        return;
      end
      chk++;
    end
    if (chk < (j_end - j0) - 4) begin
      $display("tb_serializer: FAIL %s: only %0d of %0d symbols reached the line", name, chk,
               j_end - j0);
      errors++;
    end
    total_checked += chk;
  endtask

  // One run: reset, release at a chosen clk_pix_5x phase, stream npix symbols.
  task automatic trial(input integer phase, input integer npix);
    recording = 1'b0;
    reset_n   = 1'b0;
    repeat (3) @(posedge clk_pix);
    ns        = 0;
    nb        = 0;
    recording = 1'b1;
    repeat (phase) @(posedge clk_pix_5x);
    #0.2 reset_n = 1'b1;
    repeat (npix) @(posedge clk_pix);
    recording = 1'b0;
    #3;
    // The first few symbols go out before the model's first load; the stream
    // is checked from symbol 2.
    check_from($sformatf("phase %0d", phase), 2, 0, ns - 2);
  endtask

  // A reset in mid-stream: the line goes low while reset_n is held, and the
  // symbols sent after the release reach the line intact.
  task automatic trial_rereset;
    integer restart, low_bad;
    recording = 1'b0;
    reset_n   = 1'b0;
    repeat (3) @(posedge clk_pix);
    ns        = 0;
    nb        = 0;
    recording = 1'b1;
    #0.2 reset_n = 1'b1;
    repeat (300) @(posedge clk_pix);
    #3.3 reset_n = 1'b0;  // asynchronous: between clock edges
    low_bad = 0;
    repeat (40) begin
      @(clk_pix_5x);
      #0.7;
      if (serial !== 1'b0) low_bad++;
    end
    if (low_bad > 2) begin
      $display("tb_serializer: FAIL mid-stream reset: the line is not low while reset_n is held");
      errors++;
    end
    restart = ns;
    @(posedge clk_pix_5x);
    #0.2 reset_n = 1'b1;
    repeat (400) @(posedge clk_pix);
    recording = 1'b0;
    #3;
    check_from("before the mid-stream reset", 2, 0, restart - 40);
    check_from("after the mid-stream reset", restart + 2, 10 * (restart - 10), ns - 2);
  endtask

  initial begin
    for (int p = 0; p < 5; p++) trial(p, 600);
    trial(3, 3000);
    trial_rereset();
    if (errors == 0 && total_checked > 5000)
      $display(
          "tb_serializer: PASS (%0d symbols bit-exact, LSB first, all five reset phases and a mid-stream reset)",
          total_checked
      );
    else begin
      $display("tb_serializer: FAIL %0d error(s), %0d symbols checked", errors, total_checked);
      $fatal(1);
    end
    $finish;
  end

endmodule

`default_nettype wire

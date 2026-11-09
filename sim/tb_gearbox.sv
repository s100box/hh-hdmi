// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_gearbox.sv -- hdmi_gearbox_10to8 (four lanes) from reset, over many
// groups, at every phase of the word clock against the pixel clock.
//
// The two clocks come from a common tick as one PLL makes them: pixel = /20,
// word = /16, so 4 pixels are 5 words; the word clock's phase against the
// pixel clock is moved through all 16 ticks. Each trial resets both sides,
// releases them in a chosen order and gap, feeds random 10-bit symbols on
// every lane, and records each lane's bytes as a bitstream, bit 0 first.
// The check:
//   * the bitstream is zero until the stream starts, the start is a group
//     boundary of the sent symbols, and from there every 10-bit window is
//     the next sent symbol to the end of the trial (one slip, drop or
//     repeat anywhere fails);
//   * the four lanes start on the same symbol at the same bit;
//   * aligned = 1 and slip = 0 at the end.
// One trial resets the pixel side mid-stream: slip must be set, and the
// restarted stream must appear intact after the gearbox re-aligns.
//----------------------------------------------------------------------------
`default_nettype none

module tb_gearbox;

  localparam int LANES = 4;

  // ---- clocks: tick = 0.25 ns; pixel 5 ns, word 4 ns, word phase ph ticks ---
  logic clk_word = 1'b0, clk_pix = 1'b0;
  integer tk = 0, ph = 0;
  always begin
    clk_pix  = (tk % 20) < 10;
    clk_word = ((tk + ph) % 16) < 8;
    #0.25;
    tk = tk + 1;
  end

  logic rst_pix_n = 1'b0, rst_word_n = 1'b0;
  logic [10*LANES-1:0] sym = '0;
  logic [ 8*LANES-1:0] word;
  logic aligned, slip;

  hdmi_gearbox_10to8 #(
      .LANES(LANES)
  ) dut (
      .clk_pix   (clk_pix),
      .rst_pix_n (rst_pix_n),
      .sym_i     (sym),
      .clk_word  (clk_word),
      .rst_word_n(rst_word_n),
      .word_o    (word),
      .aligned_o (aligned),
      .slip_o    (slip)
  );

  // ---- record what the DUT samples, and what it sends ----------------------
  localparam int MAXS = 6000;
  localparam int MAXB = 10 * MAXS + 2000;
  logic [9:0] sent[LANES][MAXS];
  logic       rx  [LANES][MAXB];
  integer ns = 0, nb = 0;
  logic recording = 1'b0;

  always @(posedge clk_pix) begin
    if (recording && rst_pix_n && ns < MAXS) begin
      for (int l = 0; l < LANES; l++) sent[l][ns] = sym[10*l+:10];
      ns = ns + 1;
    end
    for (int l = 0; l < LANES; l++) sym[10*l+:10] <= 10'($urandom);
  end

  always @(posedge clk_word) begin
    if (recording && nb + 8 <= MAXB) begin
      for (int l = 0; l < LANES; l++) for (int b = 0; b < 8; b++) rx[l][nb+b] = word[8*l+b];
      nb = nb + 8;
    end
  end

  // ---- checker ---------------------------------------------------------------
  integer errors = 0, total_checked = 0;

  function automatic logic [9:0] rx_sym(input integer l, input integer o, input integer m);
    logic [9:0] s;
    for (int b = 0; b < 10; b++) s[b] = rx[l][o+10*m+b];
    return s;
  endfunction

  // Where lane l's stream starts in its bitstream (o) and which symbol
  // it starts with (j); o = -1 if the first 64 symbols never appear.
  task automatic find_start(input integer l, input integer first_sym, output integer o_found,
                            output integer j_found);
    integer o, j, m, ok;
    o_found = -1;
    j_found = -1;
    for (o = 0; o < 2000 && o + 10 * 32 < nb && o_found < 0; o++) begin
      for (j = first_sym; j < first_sym + 64 && o_found < 0; j++) begin
        ok = 1;
        for (m = 0; m < 24 && ok; m++) if (rx_sym(l, o, m) !== sent[l][j+m]) ok = 0;
        if (ok) begin
          o_found = o;
          j_found = j;
        end
      end
    end
  endtask

  // Lane l from bit o / symbol j up to symbol sym_end.
  task automatic check_lane(input string name, input integer l, input integer o, input integer j,
                            input integer first_sym, input integer sym_end, input bit zero_before);
    integer m, b, bad;
    if (o < 0) begin
      $display("tb_gearbox: FAIL %s lane %0d: the sent symbols never appear", name, l);
      errors = errors + 1;
      return;
    end
    if (((j - first_sym) % 4) != 0) begin
      $display(
          "tb_gearbox: FAIL %s lane %0d: the stream starts at symbol %0d, not a group boundary",
          name, l, j - first_sym);
      errors = errors + 1;
    end
    if (zero_before) begin
      bad = 0;
      for (b = 0; b < o; b++) if (rx[l][b] !== 1'b0) bad = bad + 1;
      if (bad != 0) begin
        $display("tb_gearbox: FAIL %s lane %0d: %0d non-zero bits before the stream", name, l, bad);
        errors = errors + 1;
      end
    end
    bad = 0;
    for (m = 0; o + 10 * (m + 1) <= nb && j + m < sym_end; m++) begin
      if (rx_sym(l, o, m) !== sent[l][j+m]) begin
        if (bad < 4)
          $display(
              "tb_gearbox: FAIL %s lane %0d: symbol %0d is %03h, expected %03h",
              name,
              l,
              j + m - first_sym,
              rx_sym(
                  l, o, m
              ),
              sent[l][j+m]
          );
        bad = bad + 1;
      end
      total_checked = total_checked + 1;
    end
    if (bad != 0) errors = errors + 1;
  endtask

  task automatic check_all(input string name, input integer first_sym, input integer sym_end,
                           input bit zero_before, output integer o0);
    integer o, j, j0;
    for (int l = 0; l < LANES; l++) begin
      find_start(l, first_sym, o, j);
      if (l == 0) begin
        o0 = o;
        j0 = j;
      end else if (o != o0 || j != j0) begin
        $display("tb_gearbox: FAIL %s: lane %0d starts at bit %0d symbol %0d, lane 0 at %0d %0d",
                 name, l, o, j, o0, j0);
        errors = errors + 1;
      end
      check_lane(name, l, o, j, first_sym, sym_end, zero_before);
    end
  endtask

  task automatic wait_ticks(input integer n);
    repeat (n) @(tk);
  endtask

  task automatic trial(input string name, input bit pix_first, input integer gap,
                       input integer npix);
    integer o0;
    recording  = 1'b0;
    rst_pix_n  = 1'b0;
    rst_word_n = 1'b0;
    repeat (6) @(posedge clk_pix);
    ns        = 0;
    nb        = 0;
    recording = 1'b1;
    if (pix_first) begin
      @(posedge clk_pix);
      rst_pix_n <= 1'b1;
      wait_ticks(gap);
      @(posedge clk_word);
      rst_word_n <= 1'b1;
    end else begin
      @(posedge clk_word);
      rst_word_n <= 1'b1;
      wait_ticks(gap);
      @(posedge clk_pix);
      rst_pix_n <= 1'b1;
    end
    repeat (npix) @(posedge clk_pix);
    recording = 1'b0;
    #2;
    check_all(name, 0, ns, 1'b1, o0);
    if (aligned !== 1'b1 || slip !== 1'b0) begin
      $display("tb_gearbox: FAIL %s: aligned=%b slip=%b at the end", name, aligned, slip);
      errors = errors + 1;
    end
  endtask

  task automatic trial_repixel(input string name);
    integer o0, restart;
    recording  = 1'b0;
    rst_pix_n  = 1'b0;
    rst_word_n = 1'b0;
    repeat (6) @(posedge clk_pix);
    ns        = 0;
    nb        = 0;
    recording = 1'b1;
    @(posedge clk_word);
    rst_word_n <= 1'b1;
    @(posedge clk_pix);
    rst_pix_n <= 1'b1;
    repeat (402) @(posedge clk_pix);
    rst_pix_n <= 1'b0;
    repeat (13) @(posedge clk_pix);
    if (slip !== 1'b1) begin
      $display("tb_gearbox: FAIL %s: slip=%b after the pixel side stopped, want 1", name, slip);
      errors = errors + 1;
    end
    restart = ns;
    rst_pix_n <= 1'b1;
    repeat (600) @(posedge clk_pix);
    recording = 1'b0;
    #2;
    // the restarted stream: find it after the gap and check it to the end
    begin : after
      integer o, j;
      for (int l = 0; l < LANES; l++) begin
        o = -1;
        j = -1;
        for (
            int ob = 10 * (restart - 16);
            ob < 10 * (restart + 60) && ob + 10 * 32 < nb && o < 0;
            ob++
        ) begin
          bit ok;
          ok = 1;
          for (int m = 0; m < 24 && ok; m++) if (rx_sym(l, ob, m) !== sent[l][restart+m]) ok = 0;
          if (ok) begin
            o = ob;
            j = restart;
          end
        end
        check_lane({name, " (after)"}, l, o, j, restart, ns, 1'b0);
      end
    end
    if (aligned !== 1'b1 || slip !== 1'b1) begin
      $display("tb_gearbox: FAIL %s: want aligned=1 slip=1 after the gap, got %b %b", name,
               aligned, slip);
      errors = errors + 1;
    end
    // slip is sticky until rst_word_n: a word-side reset clears it and aligned.
    @(posedge clk_word);
    rst_word_n <= 1'b0;
    repeat (3) @(posedge clk_word);
    #1;
    if (aligned !== 1'b0 || slip !== 1'b0) begin
      $display("tb_gearbox: FAIL %s: rst_word_n left aligned=%b slip=%b, want 0 0", name, aligned,
               slip);
      errors = errors + 1;
    end
    rst_word_n <= 1'b1;
  endtask

  initial begin
    for (int p = 0; p < 16; p++) begin
      ph = p;
      trial($sformatf("word first, phase %0d", p), 1'b0, 3 + 5 * p, 1200);
      trial($sformatf("pixel first, phase %0d", p), 1'b1, 7 + 11 * p, 1200);
    end
    ph = 5;
    trial("pixel first, long gap", 1'b1, 900, 1200);
    trial_repixel("pixel reset mid-stream");
    if (errors == 0) $display("tb_gearbox: PASS (34 trials, %0d symbols checked)", total_checked);
    else $display("tb_gearbox: FAIL (%0d errors)", errors);
    $finish;
  end

endmodule

`default_nettype wire

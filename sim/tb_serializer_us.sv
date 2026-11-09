// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_serializer_us.sv -- hdmi_serializer_us (10:8 gearbox + 8:1 DDR) from
// reset, over many words.
//
// The three clocks are made the way one MMCM makes them: from a common tick,
// bit = /2, word = /8, pixel = /10, rising edges coinciding every 40 ticks.
// Each trial resets both sides, releases the two resets in a chosen order
// and phase, feeds random 10-bit symbols, and records the serial line at the
// middle of every bit. The check then:
//   * finds where the first sent symbol appears in the bitstream (LSB first)
//     and requires every later 10-bit window up to the end of the trial to
//     equal the next sent symbol -- one slip, drop or repeat anywhere fails;
//   * requires the line to be idle (0) before that point;
//   * when the word side leaves reset first, requires the first symbol after
//     rst_pix_n to be the first on the wire (nothing lost from reset);
//     otherwise the stream may start only at a 4-symbol group boundary;
//   * requires aligned = 1 and slip = 0 at the end.
// One trial pulses rst_pix_n mid-stream: the gearbox must report the gap
// (slip = 1) and re-lock with the restarted stream intact.
//----------------------------------------------------------------------------
`default_nettype none

module tb_serializer_us;

  // ---- clocks: tick = 0.5 ns; bit 1 ns, word 4 ns, pixel 5 ns --------------
  logic clk_bit = 1'b0, clk_word = 1'b0, clk_pix = 1'b0;
  integer tk = 0;
  always begin
    clk_bit  = (tk % 2) < 1;
    clk_word = (tk % 8) < 4;
    clk_pix  = (tk % 10) < 5;
    #0.5;
    tk = tk + 1;
  end

  logic rst_pix_n = 1'b0, rst_word_n = 1'b0;
  logic [9:0] parallel = 10'd0;
  logic serial, aligned, slip;

  hdmi_serializer_us dut (
      .clk_pix   (clk_pix),
      .rst_pix_n (rst_pix_n),
      .parallel  (parallel),
      .clk_word  (clk_word),
      .rst_word_n(rst_word_n),
      .clk_bit   (clk_bit),
      .serial    (serial),
      .aligned   (aligned),
      .slip      (slip)
  );

  // ---- record what the DUT samples, and what it sends ----------------------
  localparam int MAXS = 40000;
  localparam int MAXB = 10 * MAXS + 4000;
  logic [9:0] sent[MAXS];
  logic       rx  [MAXB];
  integer ns = 0, nb = 0;
  logic recording = 1'b0;

  always @(posedge clk_pix) begin
    if (recording && rst_pix_n && ns < MAXS) begin
      sent[ns] = parallel;  // the value the DUT samples on this edge
      ns       = ns + 1;
    end
    parallel <= 10'($urandom);
  end

  // Mid-bit sampling: 0.25 ns after each clk_bit edge.
  always @(clk_bit) begin
    #0.25;
    if (recording && nb < MAXB) begin
      rx[nb] = serial;
      nb     = nb + 1;
    end
  end

  // ---- checker ---------------------------------------------------------------
  integer errors = 0;

  // Symbol m of the bitstream starting at bit o.
  function automatic logic [9:0] rx_sym(input integer o, input integer m);
    logic [9:0] s;
    for (int b = 0; b < 10; b++) s[b] = rx[o+10*m+b];
    return s;
  endfunction

  // Returns the stream start (bit offset) and the index of the first sent
  // symbol found there, or o = -1 if none of the first 64 symbols is found.
  task automatic find_start(input integer first_sym, output integer o_found,
                            output integer j_found);
    integer o, j, m, ok;
    o_found = -1;
    j_found = -1;
    for (o = 0; o < 4000 && o + 10 * 32 < nb && o_found < 0; o++) begin
      for (j = first_sym; j < first_sym + 64 && o_found < 0; j++) begin
        ok = 1;
        for (m = 0; m < 24 && ok; m++) if (rx_sym(o, m) !== sent[j+m]) ok = 0;
        if (ok) begin
          o_found = o;
          j_found = j;
        end
      end
    end
  endtask

  // Check the stream from bit o / symbol j to the end of the capture.
  task automatic check_stream(input string name, input integer o, input integer j,
                              input integer first_sym, input integer j_limit, input bit need_exact,
                              input integer sym_end, output integer checked);
    integer m, b, bad;
    checked = 0;
    if (o < 0) begin
      $display("tb_serializer_us: FAIL %s: sent symbols never appear on the line", name);
      errors = errors + 1;
      return;
    end
    if (need_exact && j != first_sym) begin
      $display(
          "tb_serializer_us: FAIL %s: stream starts at symbol %0d, expected %0d (symbols lost from reset)",
          name, j - first_sym, 0);
      errors = errors + 1;
    end
    if (!need_exact && (((j - first_sym) % 4) != 0 || (j - first_sym) > j_limit)) begin
      $display(
          "tb_serializer_us: FAIL %s: stream starts at symbol %0d (want a group boundary <= %0d)",
          name, j - first_sym, j_limit);
      errors = errors + 1;
    end
    bad = 0;
    for (b = 0; b < o; b++) if (rx[b] !== 1'b0) bad = bad + 1;
    if (bad != 0) begin
      $display("tb_serializer_us: FAIL %s: %0d non-idle bits before the first symbol", name, bad);
      errors = errors + 1;
    end
    bad = 0;
    for (m = 0; o + 10 * (m + 1) <= nb && j + m < sym_end; m++) begin
      if (rx_sym(o, m) !== sent[j+m]) begin
        if (bad < 4)
          $display(
              "tb_serializer_us: FAIL %s: symbol %0d is %03h, expected %03h",
              name,
              j + m - first_sym,
              rx_sym(
                  o, m
              ),
              sent[j+m]
          );
        bad = bad + 1;
      end
      checked = checked + 1;
    end
    if (bad != 0) errors = errors + 1;
  endtask

  task automatic wait_ticks(input integer n);
    repeat (n) @(tk);
  endtask

  // One trial. pix_first = release rst_pix_n before rst_word_n; gap = ticks
  // between the two releases; npix = pixels to run afterwards.
  integer total_checked = 0;
  task automatic trial(input string name, input bit pix_first, input integer gap,
                       input integer npix);
    integer o, j, chk;
    recording  = 1'b0;
    rst_pix_n  = 1'b0;
    rst_word_n = 1'b0;
    repeat (6) @(posedge clk_pix);
    ns        = 0;
    nb        = 0;
    recording = 1'b1;
    wait_ticks(gap % 7);  // move the release phase around
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
    find_start(0, o, j);
    // Word side first: nothing may be lost. Pixel side first: the word side
    // locks on the next group after its release.
    check_stream(name, o, j, 0, 4 + 4 * ((gap / 40) + 2), !pix_first, ns, chk);
    if (aligned !== 1'b1 || slip !== 1'b0) begin
      $display("tb_serializer_us: FAIL %s: aligned=%b slip=%b at the end", name, aligned, slip);
      errors = errors + 1;
    end
    total_checked = total_checked + chk;
  endtask

  // The mid-stream pixel reset: the restarted stream must be intact.
  task automatic trial_repixel(input string name);
    integer o, j, chk, restart;
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
    repeat (500) @(posedge clk_pix);
    rst_pix_n <= 1'b0;
    repeat (13) @(posedge clk_pix);
    if (aligned !== 1'b0 || slip !== 1'b1) begin
      $display("tb_serializer_us: FAIL %s: during the input gap aligned=%b slip=%b, want 0 1",
               name, aligned, slip);
      errors = errors + 1;
    end
    restart = ns;  // first symbol after the restart
    rst_pix_n <= 1'b1;
    repeat (600) @(posedge clk_pix);
    recording = 1'b0;
    #2;
    // Before the gap: intact up to the reset.
    find_start(0, o, j);
    check_stream({name, " (before)"}, o, j, 0, 0, 1'b1, restart - 8, chk);
    total_checked = total_checked + chk;
    // After the gap: a new stream starting at the restart symbol.
    begin : after
      integer oo, jj, mm, ok;
      oo = -1;
      jj = -1;
      for (
          int ob = o + 10 * (restart - 8);
          ob < o + 10 * (restart + 40) && ob + 10 * 32 < nb && oo < 0;
          ob++
      ) begin
        ok = 1;
        for (mm = 0; mm < 24 && ok; mm++) if (rx_sym(ob, mm) !== sent[restart+mm]) ok = 0;
        if (ok) begin
          oo = ob;
          jj = restart;
        end
      end
      if (oo < 0) begin
        $display("tb_serializer_us: FAIL %s: the restarted stream never appears (no re-lock)",
                 name);
        errors = errors + 1;
      end else begin
        chk = 0;
        for (mm = 0; oo + 10 * (mm + 1) <= nb && jj + mm < ns; mm++) begin
          if (rx_sym(oo, mm) !== sent[jj+mm]) begin
            $display("tb_serializer_us: FAIL %s: after re-lock symbol %0d is %03h, expected %03h",
                     name, mm, rx_sym(oo, mm), sent[jj+mm]);
            errors = errors + 1;
            break;
          end
          chk = chk + 1;
        end
        total_checked = total_checked + chk;
      end
    end
    if (aligned !== 1'b1 || slip !== 1'b1) begin
      $display("tb_serializer_us: FAIL %s: want aligned=1 slip=1 after the gap, got %b %b", name,
               aligned, slip);
      errors = errors + 1;
    end
    // slip is sticky until rst_word_n: a word-side reset clears it and aligned.
    @(posedge clk_word);
    rst_word_n <= 1'b0;
    repeat (3) @(posedge clk_word);
    #1;
    if (aligned !== 1'b0 || slip !== 1'b0) begin
      $display("tb_serializer_us: FAIL %s: rst_word_n left aligned=%b slip=%b, want 0 0", name,
               aligned, slip);
      errors = errors + 1;
    end
    rst_word_n <= 1'b1;
  endtask

  initial begin
    // Word side first, every release phase within the 40-tick common period.
    for (int g = 0; g < 40; g += 3) trial($sformatf("word-first gap=%0d", g), 1'b0, g, 300);
    // Pixel side first, including gaps of several groups.
    for (int g = 0; g < 200; g += 17) trial($sformatf("pix-first gap=%0d", g), 1'b1, g, 300);
    // Many words in one run.
    trial("long run", 1'b0, 5, 30000);
    trial_repixel("pixel reset mid-stream");

    if (errors == 0 && total_checked > 35000)
      $display(
          "tb_serializer_us: PASS (%0d symbols checked bit-exact across %0d trials, no slips)",
          total_checked,
          14 + 12 + 2
      );
    else if (errors == 0)
      $display("tb_serializer_us: FAIL only %0d symbols checked", total_checked);
    else $display("tb_serializer_us: FAIL %0d error(s)", errors);
    $finish;
  end

endmodule

`default_nettype wire

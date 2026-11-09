// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_cec.sv  --  self-checking gate for hdmi_cec (the CEC follower).
//
// A behavioral "TV" drives the shared CEC line (open-drain wired-AND) as an
// initiator and passively monitors it as a receiver. It checks that hdmi_cec:
//   * ACKs frames addressed to its Logical Address (4),
//   * decodes <User Control Pressed>/<Released> through the KEY_UI map into the
//     key outputs, a KEY_PULSE key as a one-clock pulse,
//   * holds a pressed key (synthesized one-shot) and drops it on release and on
//     timeout,
//   * dumps the received frame as hex over the debug UART, pausing while
//     uart_ready is low, for frames of 2 to 16 blocks,
//   * replies to <Give OSD Name> with <Set OSD Name> OSD_NAME, sized to the name
//     (a 14-character name here, so the reply is a full 16-block frame),
//   * neither ACKs nor decodes a frame for another logical address, and latches
//     a broadcast <Standby> without ACKing it,
//   * ignores a short glitch on an idle line,
//   * holds One Touch Play back while a frame is on the line after a reset, and
//   * keeps working after an idle line saturates its low-time counter.
// Bit timings are shrunk via parameters for a fast sim. Exits non-zero on error.
//----------------------------------------------------------------------------
`default_nettype none

module tb_cec;
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // Shrunken CEC timings (clocks). Thresholds mirror the DUT's localparams.
  localparam int SL = 37, ZL = 15, OL = 6, BP = 24, HC = 200;
  localparam int DTH = (OL + ZL) / 2;  // data '1'/'0' threshold = 10
  localparam int STH = (ZL + SL) / 2;  // start threshold = 26

  logic dut_oe;
  logic tv_oe = 1'b0;
  wire  cec = ~(dut_oe | tv_oe);  // pull-up; both sides open-drain

  // Bench key map: Up, Down, Left, Right, Select as held keys; Exit as a pulse.
  localparam int unsigned NK = 6;
  localparam logic [8*NK-1:0] KMAP = {8'h0D, 8'h00, 8'h04, 8'h03, 8'h02, 8'h01};
  localparam logic [NK-1:0] KPULSE = 6'b100000;
  localparam logic [111:0] NAME = "HH-HDMI-BENCH1";
  localparam int NAME_LEN = 14;

  logic [NK-1:0] k;
  wire ku = k[0], kd = k[1], kl = k[2], kr = k[3], ksel = k[4], kexit = k[5];
  logic standby;
  logic [7:0] ud;
  logic uwe;
  logic uready = 1'b1;
  hdmi_cec #(
      .START_LOW(SL),
      .START_PER(47),
      .ZERO_LOW (ZL),
      .ONE_LOW  (OL),
      .BIT_PER  (BP),
      .HOLD_CYC (HC),
      .BOOT_CYC (400),
      .OUR_ADDR (4'd4),
      .PHYS_ADDR(16'h1000),
      .OSD_NAME (NAME),
      .NKEYS    (NK),
      .KEY_UI   (KMAP),
      .KEY_PULSE(KPULSE)
  ) dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .cec_oe     (dut_oe),
      .cec_in     (cec),
      .cec_standby(standby),
      .key        (k),
      .uart_data  (ud),
      .uart_we    (uwe),
      .uart_ready (uready)
  );

  // Capture the UART dump.
  logic [7:0] dump[4096];
  integer dn = 0;
  integer we_unready = 0;  // uart_we while uart_ready was low
  always_ff @(posedge clk) begin
    if (uwe && dn < 4096) begin
      dump[dn] <= ud;
      dn       <= dn + 1;
    end
    if (uwe && !uready) we_unready <= we_unready + 1;
  end

  integer errors = 0;

  // Count the clocks the pulse key spends high.
  integer exit_clk = 0;
  always_ff @(posedge clk) if (kexit) exit_clk <= exit_clk + 1;

  // ── TV transmitter (drives tv_oe) ─────────────────────────────────────────
  task automatic tlow(input integer n);
    begin
      tv_oe = 1'b1;
      repeat (n) @(posedge clk);
    end
  endtask
  task automatic thigh(input integer n);
    begin
      tv_oe = 1'b0;
      repeat (n) @(posedge clk);
    end
  endtask
  // Start bit: low 3.7 ms then a high gap (its period is longer than a data bit).
  task automatic tstart;
    begin
      tlow(SL);
      thigh(10);
    end
  endtask
  task automatic tbit(input logic v);
    integer lo;
    begin
      lo = v ? OL : ZL;
      tlow(lo);
      thigh(BP - lo);
    end
  endtask
  // ACK bit: drive the low start, release, sample (low = DUT acked), finish.
  task automatic tackbit(output logic acked);
    begin
      tv_oe = 1'b1;
      repeat (OL) @(posedge clk);
      tv_oe = 1'b0;
      repeat (DTH - OL + 1) @(posedge clk);
      acked = ~cec;
      repeat (BP - DTH - 1) @(posedge clk);
    end
  endtask
  task automatic tbyte(input logic [7:0] d, input logic eom, output logic acked);
    integer i;
    begin
      for (i = 7; i >= 0; i = i - 1) tbit(d[i]);
      tbit(eom);
      tackbit(acked);
    end
  endtask
  // A frame of any length up to 16 blocks; block i is b[8*i+:8].
  task automatic tframe_n(input logic [127:0] b, input integer n, output logic allack,
                          output logic anyack);
    logic a;
    begin
      allack = 1'b1;
      anyack = 1'b0;
      tstart();
      for (int i = 0; i < n; i++) begin
        tbyte(b[8*i+:8], i == n - 1, a);
        allack = allack & a;
        anyack = anyack | a;
      end
    end
  endtask
  task automatic tframe(input logic [7:0] b0, input logic [7:0] b1, input logic [7:0] b2,
                        input integer n, output logic allack);
    logic a;
    begin
      allack = 1'b1;
      tstart();
      tbyte(b0, n == 1, a);
      allack = allack & a;
      if (n >= 2) begin
        tbyte(b1, n == 2, a);
        allack = allack & a;
      end
      if (n >= 3) begin
        tbyte(b2, n == 3, a);
        allack = allack & a;
      end
    end
  endtask

  // ── Passive monitor (decode one frame on the line) ────────────────────────
  task automatic wait_low(output integer dur);
    integer c;
    begin
      @(negedge cec);
      c = 0;
      while (!cec) begin
        @(posedge clk);
        c = c + 1;
      end
      dur = c;
    end
  endtask
  logic [7:0] mon[16];
  integer mlen;
  // Decode one frame: skip until a start bit (low > STH), then read each block's
  // 8 data + EOM + ACK bits. Re-syncs at frame boundaries.
  task automatic mon_capture;
    integer d, i, by;
    logic eom;
    begin
      d = 0;
      do wait_low(d); while (d <= STH);
      mlen = 0;
      eom  = 1'b0;
      while (!eom && mlen < 16) begin
        by = 0;
        for (i = 0; i < 8; i = i + 1) begin
          wait_low(d);
          by = (by << 1) | ((d < DTH) ? 1 : 0);
        end
        wait_low(d);
        eom = (d < DTH);
        wait_low(d);  // ACK slot
        mon[mlen] = by[7:0];
        mlen      = mlen + 1;
      end
    end
  endtask

  // Background monitor: latch every completed frame into last[]/last_len, and
  // flag the One Touch Play and Set OSD Name frames the DUT (src nibble 4)
  // transmits.
  logic [7:0] last[16];
  integer last_len = 0;
  integer j;
  logic saw_ivo = 1'b0, saw_as = 1'b0, saw_osd = 1'b0;
  initial begin : bgmon
    forever begin
      mon_capture();
      for (j = 0; j < mlen; j = j + 1) last[j] = mon[j];
      last_len = mlen;
      if (mlen >= 2 && mon[0][7:4] == 4'd4) begin
        if (mon[1] == 8'h04) saw_ivo = 1'b1;  // Image View On
        if (mon[1] == 8'h82 && mon[0][3:0] == 4'hF) saw_as = 1'b1;  // Active Source
        if (mon[1] == 8'h47 && mon[0] == 8'h40 && mlen == 2 + NAME_LEN) saw_osd = 1'b1;
      end
    end
  end

  initial begin
    #40000000 $fatal(1, "TB_CEC FAIL: watchdog timed out");
  end

  // Clock count at the edges of the Right key, for the hold-length check.
  integer cyc = 0, kr_rise = 0, kr_fall = 0;
  always @(posedge clk) cyc <= cyc + 1;
  always @(posedge kr) kr_rise = cyc;
  always @(negedge kr) kr_fall = cyc;

  function automatic logic [7:0] hexch(input logic [3:0] n);
    return (n < 10) ? 8'h30 + n : 8'h41 + (n - 10);
  endfunction

  logic allack;
  integer kk, jj;
  initial begin
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // The asynchronous pad must cross both input stages before edge detection.
    // These checks exercise each edge away from the sampling clock; they
    // verify digital staging, not analog metastability behavior.
    @(negedge clk);
    tv_oe = 1'b1;
    #1;
    if (dut.fall !== 1'b0) $fatal(1, "CEC fall bypassed the input synchronizer");
    @(posedge clk);
    #1;
    if (dut.fall !== 1'b0) $fatal(1, "CEC fall used the first input stage");
    @(posedge clk);
    #1;
    if (dut.fall !== 1'b1) $fatal(1, "CEC fall missing after both input stages");
    @(posedge clk);
    #1;
    if (dut.fall !== 1'b0) $fatal(1, "CEC falling edge repeated");
    @(negedge clk);
    tv_oe = 1'b0;
    #1;
    if (dut.rise !== 1'b0) $fatal(1, "CEC rise bypassed the input synchronizer");
    @(posedge clk);
    #1;
    if (dut.rise !== 1'b0) $fatal(1, "CEC rise used the first input stage");
    @(posedge clk);
    #1;
    if (dut.rise !== 1'b1) $fatal(1, "CEC rise missing after both input stages");
    repeat (5) @(posedge clk);

    // 0) One Touch Play: the DUT transmits Image View On + Active Source on boot
    // (TV stays quiet so the line is idle for it).
    kk = 0;
    while (!(saw_ivo && saw_as) && kk < 40000) begin
      @(posedge clk);
      kk++;
    end
    if (!saw_ivo) begin
      $display("FAIL: no Image View On at boot");
      errors++;
    end
    if (!saw_as) begin
      $display("FAIL: no Active Source at boot");
      errors++;
    end

    // 1) User Control Pressed = Up -> key_up, with ACK.
    tframe(8'h04, 8'h44, 8'h01, 3, allack);
    if (!allack) begin
      $display("FAIL: directed frame not ACKed");
      errors++;
    end
    if (!ku) begin
      $display("FAIL: Up not decoded");
      errors++;
    end

    // 2) Hold persists for a while without a repeat.
    repeat (50) @(posedge clk);
    if (!ku) begin
      $display("FAIL: hold dropped early");
      errors++;
    end

    // 3) Release drops it.
    tframe(8'h04, 8'h45, 8'h00, 2, allack);
    if (ku) begin
      $display("FAIL: Up not released");
      errors++;
    end

    // 4) Synthesized-hold timeout: press Right, never release, wait out the
    //    hold, which lasts HOLD_CYC clocks from the Pressed.
    tframe(8'h04, 8'h44, 8'h04, 3, allack);
    if (!kr) begin
      $display("FAIL: Right not decoded");
      errors++;
    end
    kk = 0;
    while (kr && kk < HC + 200) begin
      @(posedge clk);
      kk++;
    end
    if (kr) begin
      $display("FAIL: hold never timed out");
      errors++;
    end else if (kr_fall - kr_rise < HC - 1 || kr_fall - kr_rise > HC + 1) begin
      $display("FAIL: Right held %0d clocks, want HOLD_CYC = %0d", kr_fall - kr_rise, HC);
      errors++;
    end

    // 4b) A pulse key: Exit asserts key[5] for exactly one clock and drops the
    //     held keys; a Pressed of an unmapped code asserts nothing.
    tframe(8'h04, 8'h44, 8'h02, 3, allack);
    if (!kd) begin
      $display("FAIL: Down not decoded");
      errors++;
    end
    tframe(8'h04, 8'h44, 8'h0D, 3, allack);
    repeat (20) @(posedge clk);
    if (exit_clk != 1) begin
      $display("FAIL: Exit pulse lasted %0d clocks, not 1", exit_clk);
      errors++;
    end
    if (kd) begin
      $display("FAIL: Down still held after another key's Pressed");
      errors++;
    end
    tframe(8'h04, 8'h44, 8'h71, 3, allack);  // F1 (Blue): not in the map
    repeat (20) @(posedge clk);
    if (k != '0) begin
      $display("FAIL: unmapped key asserted %b", k);
      errors++;
    end
    tframe(8'h04, 8'h45, 8'h00, 2, allack);

    // 5) Serial dump of frame 1 starts "04 44 01".
    if (dump[0] != "0" || dump[1] != "4" || dump[2] != " " || dump[3] != "4" ||
        dump[4] != "4" || dump[5] != " " || dump[6] != "0" || dump[7] != "1") begin
      $display("FAIL: dump prefix %c%c%c%c%c%c%c%c", dump[0], dump[1], dump[2], dump[3], dump[4],
               dump[5], dump[6], dump[7]);
      errors++;
    end

    // 6) Give OSD Name -> DUT replies Set OSD Name OSD_NAME, 2 + NAME_LEN blocks.
    tframe(8'h04, 8'h46, 8'h00, 2, allack);
    if (!allack) begin
      $display("FAIL: Give-OSD-Name not ACKed");
      errors++;
    end
    kk = 0;
    while (!(last_len >= 2 + NAME_LEN && last[0] == 8'h40) && kk < 40000) begin
      @(posedge clk);
      kk++;
    end
    if (last[0] != 8'h40) begin
      $display("FAIL: reply header %02h != 40", last[0]);
      errors++;
    end
    if (last[1] != 8'h47) begin
      $display("FAIL: reply opcode %02h != 47", last[1]);
      errors++;
    end
    if (last_len != 2 + NAME_LEN) begin
      $display("FAIL: reply length %0d != %0d", last_len, 2 + NAME_LEN);
      errors++;
    end
    for (jj = 0; jj < NAME_LEN; jj = jj + 1) begin
      if (last[2+jj] != NAME[8*(NAME_LEN-1-jj)+:8]) begin
        $display("FAIL: OSD name byte %0d = %c, want %c", jj, last[2+jj],
                 NAME[8*(NAME_LEN-1-jj)+:8]);
        errors++;
      end
    end

    // 7) Standby: a <Standby> sets cec_standby; a remote key clears it.
    tframe(8'h04, 8'h36, 8'h00, 2, allack);
    repeat (20) @(posedge clk);
    if (!standby) begin
      $display("FAIL: Standby not latched");
      errors++;
    end
    tframe(8'h04, 8'h44, 8'h01, 3, allack);  // a key wakes us
    repeat (20) @(posedge clk);
    if (standby) begin
      $display("FAIL: Standby not cleared by key");
      errors++;
    end

    // 8) Every mapped key in turn: a held key raises exactly its own output; the
    //    pulse key (Exit) was checked above.
    for (int i = 0; i < NK - 1; i++) begin
      tframe(8'h04, 8'h44, KMAP[8*i+:8], 3, allack);
      repeat (4) @(posedge clk);
      if (k !== (NK'(1) << i)) begin
        $display("FAIL: key code %02h raised %b, want only bit %0d", KMAP[8*i+:8], k, i);
        errors++;
      end
    end
    tframe(8'h04, 8'h45, 8'h00, 2, allack);
    repeat (4) @(posedge clk);
    if (k !== '0) begin
      $display("FAIL: keys %b still held after Released", k);
      errors++;
    end

    // 9) Frames for other logical addresses (3, then 5): no ACK, no key, no
    //    standby.
    tframe(8'h03, 8'h44, 8'h01, 3, allack);
    repeat (20) @(posedge clk);
    if (allack) begin
      $display("FAIL: a frame for LA 3 was ACKed");
      errors++;
    end
    if (k !== '0) begin
      $display("FAIL: a frame for LA 3 raised keys %b", k);
      errors++;
    end
    tframe(8'h05, 8'h36, 8'h00, 2, allack);
    repeat (20) @(posedge clk);
    if (standby) begin
      $display("FAIL: a <Standby> for LA 5 set standby");
      errors++;
    end

    // 10) A broadcast <Standby> (destination F) is latched and not ACKed.
    tframe(8'h0F, 8'h36, 8'h00, 2, allack);
    repeat (20) @(posedge clk);
    if (!standby) begin
      $display("FAIL: a broadcast <Standby> was not latched");
      errors++;
    end
    if (allack) begin
      $display("FAIL: a broadcast frame was ACKed");
      errors++;
    end
    tframe(8'h04, 8'h44, 8'h01, 3, allack);
    tframe(8'h04, 8'h45, 8'h00, 2, allack);

    // 11) A glitch on the idle line (shorter than any bit) is ignored, and the
    //     next frame still decodes.
    tlow(OL - 2);
    thigh(3 * BP);
    tframe(8'h04, 8'h44, 8'h03, 3, allack);
    repeat (4) @(posedge clk);
    if (!allack || k !== 6'b000100) begin
      $display("FAIL: after a line glitch the next frame gave ack=%b keys=%b", allack, k);
      errors++;
    end
    tframe(8'h04, 8'h45, 8'h00, 2, allack);

    // 12) Long frames with an unknown opcode: 16 blocks, 16 blocks of the
    //     complement from initiator F, 13 blocks, then 16 blocks again, so every
    //     header, opcode and operand bit is written both ways. Each is ACKed,
    //     raises no key and draws no reply, and is dumped in full as hex; the
    //     second one's dump waits while uart_ready is low.
    for (int f = 0; f < 4; f++) begin
      logic [127:0] fb;
      logic anyack;
      integer start_dn, pos, nb;
      nb       = (f == 2) ? 13 : 16;
      fb       = '0;
      fb[7:0]  = (f == 1) ? 8'hF4 : 8'h04;
      fb[15:8] = (f == 1) ? 8'h66 : 8'h99;
      for (int i = 2; i < nb; i++)
      fb[8*i+:8] = (f == 1) ? ~8'(8'h5A ^ (i * 8'h11)) : 8'(8'h5A ^ (i * 8'h11));
      while (dut.dumping) @(posedge clk);
      repeat (3) @(posedge clk);  // the newline lands in dump[] after dumping drops
      start_dn = dn;
      if (f == 1) uready = 1'b0;
      tframe_n(fb, nb, allack, anyack);
      if (!allack) begin
        $display("FAIL: %0d-block frame %0d not ACKed throughout", nb, f);
        errors++;
      end
      if (f == 1) begin
        repeat (200) @(posedge clk);
        uready = 1'b1;
      end
      repeat (200) @(posedge clk);
      if (k !== '0) begin
        $display("FAIL: an unknown opcode raised keys %b", k);
        errors++;
      end
      if (dn - start_dn != 3 * nb + 1) begin
        $display("FAIL: %0d-block frame %0d dumped %0d characters, want %0d", nb, f, dn - start_dn,
                 3 * nb + 1);
        errors++;
      end else begin
        for (int i = 0; i < nb; i++) begin
          pos = start_dn + 3 * i;
          if (dump[pos] !== hexch(
                  fb[8*i+4+:4]
              ) || dump[pos+1] !== hexch(
                  fb[8*i+:4]
              ) || dump[pos+2] !== 8'h20) begin
            $display("FAIL: dump of block %0d reads %c%c%c, want %02h", i, dump[pos], dump[pos+1],
                     dump[pos+2], fb[8*i+:8]);
            errors++;
          end
        end
        if (dump[start_dn+3*nb] !== 8'h0A) begin
          $display("FAIL: dump not ended by a newline");
          errors++;
        end
      end
    end
    if (we_unready != 0) begin
      $display("FAIL: %0d dump characters written while uart_ready was low", we_unready);
      errors++;
    end

    // 13) A reset, and a <Give OSD Name> already on the line when One Touch
    //     Play comes due (BOOT_CYC = 400): the DUT waits for the line, then
    //     sends all three frames, none lost to the other.
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    saw_ivo = 1'b0;
    saw_as  = 1'b0;
    saw_osd = 1'b0;
    rst_n   = 1'b1;
    repeat (350) @(posedge clk);
    tframe(8'h04, 8'h46, 8'h00, 2, allack);
    if (!allack) begin
      $display("FAIL: Give OSD Name during the boot wait not ACKed");
      errors++;
    end
    if (saw_ivo) begin
      $display("FAIL: Image View On went out while a frame was on the line");
      errors++;
    end
    kk = 0;
    while (!(saw_ivo && saw_as && saw_osd) && kk < 80000) begin
      @(posedge clk);
      kk++;
    end
    if (!saw_ivo || !saw_as || !saw_osd) begin
      $display("FAIL: after the deferred boot sent IVO %b AS %b OSD reply %b, want all three",
               saw_ivo, saw_as, saw_osd);
      errors++;
    end

    // 14) An idle line long enough to saturate the low-time counter (its width
    //     follows START_PER), then a frame that still decodes.
    repeat ((1 << $bits(dut.t)) + 10) @(posedge clk);
    if (dut.t !== '1) begin
      $display("FAIL: low-time counter %h, not saturated after a long idle", dut.t);
      errors++;
    end
    tframe(8'h04, 8'h44, 8'h02, 3, allack);
    repeat (4) @(posedge clk);
    if (!allack || !kd) begin
      $display("FAIL: after a long idle the frame gave ack=%b down=%b", allack, kd);
      errors++;
    end

    // Short frames must not dispatch an opcode or operand left in frame[]
    // by a longer frame. A poll has only a header; Pressed needs an operand.
    tframe(8'h04, 8'h44, 8'h02, 3, allack);
    repeat (HC + 20) @(posedge clk);
    tframe(8'h04, 8'h00, 8'h00, 1, allack);
    repeat (4) @(posedge clk);
    if (k !== '0) begin
      $display("FAIL: header-only poll reused a stale key opcode");
      errors++;
    end
    tframe(8'h04, 8'h44, 8'h00, 2, allack);
    repeat (4) @(posedge clk);
    if (k !== '0) begin
      $display("FAIL: Pressed without an operand reused a stale key");
      errors++;
    end
    tframe(8'h04, 8'h36, 8'h00, 2, allack);
    tframe(8'h04, 8'h44, 8'h00, 2, allack);
    repeat (4) @(posedge clk);
    if (standby !== 1'b1) begin
      $display("FAIL: Pressed without an operand cleared standby");
      errors++;
    end

    // A frame without EOM in its first 16 blocks is malformed. Its tail
    // must not wrap the receive buffer and become a second, valid command.
    tstart();
    tbyte(8'h04, 1'b0, allack);
    tbyte(8'h99, 1'b0, allack);
    for (int i = 2; i < 16; i++) tbyte(8'h00, 1'b0, allack);
    tbyte(8'h04, 1'b0, allack);
    tbyte(8'h44, 1'b0, allack);
    tbyte(8'h02, 1'b1, allack);
    repeat (4) @(posedge clk);
    if (k !== '0 || standby !== 1'b1) begin
      $display("FAIL: overlength CEC frame wrapped into a key command");
      errors++;
    end
    tframe(8'h04, 8'h44, 8'h01, 3, allack);
    repeat (4) @(posedge clk);
    if (ku !== 1'b1 || standby !== 1'b0) begin
      $display("FAIL: valid frame did not recover after an overlength frame");
      errors++;
    end

    if (errors == 0) begin
      $display("TB_CEC PASS — OTP(IVO+AS, deferred), ACK, other LA, broadcast standby, glitch, ",
               "keys+hold+pulse, 16-block dump, 14-char OSD reply, t saturation, ",
               "input synchronization, short/overlength frame rejection and recovery");
      $finish;
    end else $fatal(1, "TB_CEC FAIL (%0d errors)", errors);
  end
endmodule

`default_nettype wire

// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_edid_i2c.sv -- self-checking bench for the DDC/E-DDC EDID reader.
//
// A behavioral I2C EEPROM slave holds a 512-byte image and follows the exact
// sequence the master issues:
//   segment 0: START, A0, offset, RSTART, A1, 256 reads, STOP
//   segment 1: START, 60(seg-ptr), 01, RSTART, A0, offset, RSTART, A1, 256, STOP
// or, in its NAK mode, acknowledges nothing (no sink). A model of the DUT's
// 512-byte store is kept beside it, and after every read the whole CPU window
// (0..511) is compared against the model, so a stray write anywhere shows up.
// The reads, in order:
//   1. the auto-read after reset, extension count 3: all four blocks;
//   2. a hot-plug rising edge, extension count 1: segment 0 only, blocks 2-3
//      keep the last read's bytes; a start pulse and a second hot-plug edge
//      while busy are ignored;
//   3. a start pulse, extension count 0xFF: both segments;
//   4. no sink: err rises, valid falls, the store is untouched;
//   5. a reset in the middle of segment 1: the auto-read after it restarts
//      cleanly and reads all four blocks;
//   6. a state code outside the enum forced in mid-read (fault injection): the
//      DUT finishes with the bus released and no done pulse, and the next start
//      reads all four blocks.
//   7. a start pulse in the non-busy done cycle begins the next read.
// The open-drain bus is a wired-AND of the master and slave low-drivers with a
// pull-up.
//----------------------------------------------------------------------------
`default_nettype none

module tb_edid_i2c #(
    parameter int unsigned SDA_DELAY_NS = 0,
    parameter int unsigned BUS_QUARTER  = 7
);
  logic clk = 0;
  always #18 clk = ~clk;  // ~27.8 MHz
  logic rst_n = 0;
  logic start = 0, hpd = 0;

  // Open-drain bus: master (DUT) + slave low-drivers, pulled up.
  wire scl, sda;
  logic m_scl_o, m_sda_oe;  // from DUT
  logic s_sda_low = 0;  // slave low-driver (this bench)
  pullup (scl);
  pullup (sda);
  assign scl = m_scl_o ? 1'bz : 1'b0;
  // Delayed slave edges exercise the synchronizer at a different clock phase.
  wire slave_low_delayed;
  assign #(SDA_DELAY_NS) slave_low_delayed = s_sda_low;
  assign                 sda               = (m_sda_oe || slave_low_delayed) ? 1'b0 : 1'bz;

  // DUT.
  logic busy, valid, done, err;
  logic [8:0] cpu_addr = 0;
  logic [7:0] cpu_data;
  edid_i2c #(
      .CLK_HZ(BUS_QUARTER * 4_000_000),
      .I2C_HZ(1_000_000)
  ) dut (
      .clk     (clk),
      .rst_n   (rst_n),
      .start   (start),
      .hpd     (hpd),
      .busy    (busy),
      .valid   (valid),
      .done    (done),
      .err     (err),
      .cpu_addr(cpu_addr),
      .cpu_data(cpu_data),
      .scl_o   (m_scl_o),
      .sda_oe  (m_sda_oe),
      .sda_in  (sda)
  );

  integer n_done = 0;
  always @(posedge clk) if (done) n_done <= n_done + 1;

  // EEPROM image, and the bench's model of the DUT's store.
  logic [7:0] rom[512];
  logic [7:0] model[512];
  integer slave_nak = 0;  // 1 = no sink: NAK every address byte
  task automatic fill(input integer seed, input logic [7:0] ext);
    for (int k = 0; k < 512; k++) rom[k] = 8'((k * 7 + seed) ^ (k >> 3));
    rom[126] = ext;  // extension count
  endtask
  task automatic model_seg(input integer s);
    for (int k = 0; k < 256; k++) model[256*s+k] = rom[256*s+k];
  endtask

  // ---- Behavioral I2C slave tasks ----
  task automatic recv_byte(output logic [7:0] v);
    v = 0;
    for (int i = 0; i < 8; i++) begin
      @(posedge scl);
      v = {v[6:0], (sda === 1'b1)};
    end
  endtask

  // ACK for a write byte: drive low across the ACK clock.
  task automatic ack_w;
    @(negedge scl);
    s_sda_low = 1;
    @(posedge scl);
    @(negedge scl);
    s_sda_low = 0;
  endtask

  // NAK: let the ACK clock pass without driving SDA low.
  task automatic nack;
    @(negedge scl);
    @(posedge scl);
    @(negedge scl);
  endtask

  // ACK for the read-address byte: drive low one clock, leave at SCL-high so the
  // caller starts shifting data on the next falling edge.
  task automatic ack_r;
    @(negedge scl);
    s_sda_low = 1;
    @(posedge scl);
  endtask

  // Send a byte MSB-first (set up on each falling edge), then float for master (N)ACK.
  task automatic send_byte(input logic [7:0] v);
    for (int i = 0; i < 8; i++) begin
      @(negedge scl);
      s_sda_low = ~v[7-i];
    end
    @(negedge scl);
    s_sda_low = 0;  // release for master (N)ACK
    @(posedge scl);  // master drives (N)ACK (ignored)
  endtask

  // The slave restarts (disable slave) whenever the bench resets the DUT or
  // corrupts its state mid-transfer.
  logic [7:0] addr_b, off_b, seg_b;
  logic [8:0] ptr;
  always begin : slave
    @(negedge sda);
    if (scl === 1'b1) begin  // START
      seg_b = 8'd0;
      recv_byte(addr_b);
      if (slave_nak) nack;
      else begin
        ack_w;  // first byte: 0xA0 or 0x60
        if (addr_b == 8'h60) begin  // E-DDC segment pointer
          recv_byte(seg_b);
          ack_w;  // segment number
          @(negedge sda);  // repeated START (SCL high)
          recv_byte(addr_b);
          ack_w;  // A0 (write)
        end
        recv_byte(off_b);
        ack_w;  // word offset within segment
        ptr = {seg_b[0], off_b};  // global byte pointer
        @(negedge sda);  // repeated START (SCL high)
        recv_byte(addr_b);
        ack_r;  // A1 (read)
        for (int j = 0; j < 256; j++) begin
          send_byte(rom[ptr]);
          ptr = ptr + 1;
        end
        // The master NACKs the last byte and issues STOP.
      end
    end
  end

  task automatic restart_slave;
    disable slave;
    s_sda_low = 0;
  endtask

  // ---- Checks ----
  integer errors = 0;
  task automatic fail(input string what);
    errors++;
    $display("FAIL: %s", what);
  endtask

  task automatic wait_done;
    while (!done) @(posedge clk);
    @(posedge clk);
  endtask

  task automatic check_store(input string what);
    integer bad;
    bad = 0;
    for (int i = 0; i < 512; i++) begin
      @(negedge clk);
      cpu_addr = 9'(i);
      @(posedge clk);
      @(posedge clk);  // registered-read latency
      #1;
      if (cpu_data !== model[i]) begin
        bad++;
        if (bad <= 4) $display("  %s: byte %0d = %02x, want %02x", what, i, cpu_data, model[i]);
      end
    end
    cpu_addr = 9'd0;
    if (bad != 0) fail($sformatf("%s: %0d store bytes differ", what, bad));
  endtask

  task automatic check_flags(input string what, input logic want_valid, input logic want_err);
    if (valid !== want_valid || err !== want_err || busy !== 1'b0)
      fail($sformatf(
           "%s: valid=%b err=%b busy=%b, want %b %b 0", what, valid, err, busy, want_valid, want_err
           ));
  endtask

  task automatic pulse_start;
    @(negedge clk);
    start = 1;
    @(negedge clk);
    start = 0;
  endtask

  integer nd;
  initial begin
    for (int k = 0; k < 512; k++) model[k] = 8'hxx;

    // 1) Auto-read after reset: four blocks.
    fill(3, 8'd3);
    model_seg(0);
    model_seg(1);
    repeat (5) @(posedge clk);
    rst_n = 1;
    wait_done;
    check_flags("auto-read", 1'b1, 1'b0);
    check_store("auto-read");

    // 2) Hot-plug, one extension block: segment 0 only. Triggers while busy are
    //    ignored.
    fill(5, 8'd1);
    model_seg(0);
    nd = n_done;
    @(negedge clk);
    hpd = 1;
    repeat (200) @(posedge clk);
    if (!busy) fail("hot-plug edge did not start a read");
    pulse_start;
    hpd = 0;
    repeat (20) @(posedge clk);
    hpd = 1;
    wait_done;
    repeat (200) @(posedge clk);
    if (busy || n_done != nd + 1)
      fail($sformatf("hot-plug: busy=%b, %0d reads", busy, n_done - nd));
    check_flags("hot-plug", 1'b1, 1'b0);
    check_store("hot-plug");
    hpd = 0;

    // 3) Start pulse, extension count 0xFF: both segments.
    fill(9, 8'hFF);
    model_seg(0);
    model_seg(1);
    pulse_start;
    wait_done;
    check_flags("start, 255 extensions", 1'b1, 1'b0);
    check_store("start, 255 extensions");

    // 4) No sink: the read aborts with err, valid falls, the store is untouched.
    slave_nak = 1;
    fill(13, 8'd3);
    pulse_start;
    wait_done;
    check_flags("no sink", 1'b0, 1'b1);
    check_store("no sink");
    slave_nak = 0;

    // 5) A reset in the middle of segment 1; the auto-read after it restarts.
    fill(17, 8'd2);
    model_seg(0);
    model_seg(1);
    pulse_start;
    while (!(dut.seg && dut.rd_count == 8'd40)) @(posedge clk);  // reading byte 40
    @(negedge clk);
    rst_n = 0;
    restart_slave;
    repeat (3) @(posedge clk);
    if (valid || err || !busy)
      fail($sformatf("in reset: valid=%b err=%b busy=%b", valid, err, busy));
    @(negedge clk);
    rst_n = 1;
    wait_done;
    check_flags("reset mid-read", 1'b1, 1'b0);
    check_store("reset mid-read");

    // 6) Fault injection: a state code outside the enum (12-15) mid-read.
    fill(21, 8'd3);
    pulse_start;
    while (dut.rd_count != 8'd10) @(posedge clk);  // reading byte 10 of segment 0
    nd = n_done;
    @(negedge clk);
    force dut.state[3:2] = 2'b11;
    @(negedge clk);
    release dut.state[3:2];
    restart_slave;
    while (busy) @(posedge clk);
    repeat (50) @(posedge clk);
    if (n_done != nd) fail("a corrupted state pulsed done");
    if (m_scl_o !== 1'b1 || m_sda_oe !== 1'b0) fail("bus not released after a corrupted state");
    model_seg(0);
    model_seg(1);
    pulse_start;
    wait_done;
    check_flags("after a corrupted state", 1'b1, 1'b0);
    check_store("after a corrupted state");

    // 7) The completion cycle advertises !busy. A one-clock start there
    // must take priority over the terminal state's return to idle.
    pulse_start;
    @(posedge done);
    @(negedge clk);
    if (busy !== 1'b0) fail("completion cycle still busy");
    start = 1;
    @(negedge clk);
    start = 0;
    if (busy !== 1'b1) $fatal(1, "start in the done cycle was lost");
    wait_done;
    check_flags("start in done cycle", 1'b1, 1'b0);
    check_store("start in done cycle");

    if (errors == 0) begin
      $display("tb_edid_i2c: PASS (auto, hot-plug, start, no sink, reset, fault, done restart)");
      $finish;
    end else $fatal(1, "tb_edid_i2c: FAIL (%0d errors)", errors);
  end

  initial begin
    #200_000_000;
    $fatal(1, "tb_edid_i2c: TIMEOUT");
  end
endmodule

`default_nettype wire

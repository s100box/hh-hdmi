// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_edid_i2c_err.sv -- self-checking bench for the DDC reader's error handling.
//
// Two cases, driven through one DUT via a mode-selectable behavioral slave:
//   1. No sink (slave NAKs the very first address byte). The auto-read after reset
//      must abort cleanly: err=1, valid=0, busy clears, done pulses.
//   2. A sink WITHOUT E-DDC: it ACKs and returns all of segment 0 (256 bytes, with
//      the extension count byte 126 = 3 so the master tries segment 1), then NAKs
//      the 0x60 E-DDC segment pointer. The master must keep the good base blocks:
//      valid=1, err=0, and bytes 0..255 read back correctly.
//----------------------------------------------------------------------------
`default_nettype none

module tb_edid_i2c_err;
  logic clk = 0;
  always #18 clk = ~clk;  // ~27.8 MHz
  logic rst_n = 0;
  logic tb_start = 0;

  // Open-drain bus: master (DUT) + slave low-drivers, pulled up.
  wire scl, sda;
  logic m_scl_o, m_sda_oe;  // from DUT
  logic s_sda_low = 0;  // slave low-driver (this bench)
  pullup (scl);
  pullup (sda);
  assign scl = m_scl_o ? 1'bz : 1'b0;
  assign sda = (m_sda_oe || s_sda_low) ? 1'b0 : 1'bz;

  // DUT.
  logic busy, valid, done, err;
  logic [8:0] cpu_addr = 0;
  logic [7:0] cpu_data;
  edid_i2c #(
      .CLK_HZ(28_000_000),
      .I2C_HZ(1_000_000)
  ) dut (
      .clk     (clk),
      .rst_n   (rst_n),
      .start   (tb_start),
      .hpd     (1'b0),
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

  // EEPROM contents for the segment-0 read in case 2 (byte 126 = 3 -> needs seg 1).
  logic [7:0] rom[256];
  integer k;
  initial begin
    for (k = 0; k < 256; k = k + 1) rom[k] = (k * 7 + 3) & 8'hFF;
    rom[126] = 8'd3;
  end

  // slave_mode: 0 = NAK every address (no sink); 1 = ACK seg 0, NAK the 0x60 seg ptr.
  integer slave_mode = 0;

  // ---- Behavioral I2C slave tasks ----
  task recv_byte(output logic [7:0] v);
    integer i;
    begin
      v = 0;
      for (i = 0; i < 8; i = i + 1) begin
        @(posedge scl);
        v = {v[6:0], (sda === 1'b1)};
      end
    end
  endtask

  task ack_w;  // ACK a write byte: drive low across the ACK clock.
    begin
      @(negedge scl);
      s_sda_low = 1;
      @(posedge scl);
      @(negedge scl);
      s_sda_low = 0;
    end
  endtask

  task nack;  // NAK: let the ACK clock pass without driving SDA low.
    begin
      @(negedge scl);
      @(posedge scl);
      @(negedge scl);
    end
  endtask

  task ack_r;  // ACK the read-address byte (leave at SCL-high to start data).
    begin
      @(negedge scl);
      s_sda_low = 1;
      @(posedge scl);
    end
  endtask

  task send_byte(input logic [7:0] v);
    integer i;
    begin
      for (i = 0; i < 8; i = i + 1) begin
        @(negedge scl);
        s_sda_low = ~v[7-i];
      end
      @(negedge scl);
      s_sda_low = 0;  // release for master (N)ACK
      @(posedge scl);
    end
  endtask

  logic [7:0] addr_b, off_b;
  integer j;
  initial begin : slave
    forever begin
      @(negedge sda);
      if (scl !== 1'b1) continue;  // START
      recv_byte(addr_b);
      if (slave_mode == 0) begin
        nack;
      end          // no sink: NAK the address
      else if (addr_b == 8'h60) begin
        nack;
      end     // no E-DDC: NAK the segment ptr
      else begin
        ack_w;  // ACK A0 (write)
        recv_byte(off_b);
        ack_w;  // word offset
        @(negedge sda);  // repeated START
        recv_byte(addr_b);
        ack_r;  // A1 (read)
        for (j = 0; j < 256; j = j + 1) send_byte(rom[j]);
        // master NACKs the last byte + STOP, then tries seg 1 (0x60) -> NAKed above.
      end
    end
  end

  // ---- Drive + check ----
  integer errors = 0, i;
  initial begin
    // Case 1: no sink -- the post-reset auto-read must abort with err.
    slave_mode = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;

    @(posedge done);
    @(posedge clk);
    if (err !== 1'b1) begin
      errors = errors + 1;
      $display("case1 FAIL: err=%0b (exp 1)", err);
    end
    if (valid !== 1'b0) begin
      errors = errors + 1;
      $display("case1 FAIL: valid=%0b (exp 0)", valid);
    end
    if (busy !== 1'b0) begin
      errors = errors + 1;
      $display("case1 FAIL: busy=%0b (exp 0)", busy);
    end

    // Case 2: sink without E-DDC -- keep blocks 0-1, no err.
    slave_mode = 1;
    // Drive control on the falling edge so it is stable at the DUT's next
    // sampling edge, independent of simulator process ordering.
    @(negedge clk);
    tb_start = 1;
    @(negedge clk);
    tb_start = 0;

    @(posedge done);
    @(posedge clk);
    if (err !== 1'b0) begin
      errors = errors + 1;
      $display("case2 FAIL: err=%0b (exp 0)", err);
    end
    if (valid !== 1'b1) begin
      errors = errors + 1;
      $display("case2 FAIL: valid=%0b (exp 1)", valid);
    end

    for (i = 0; i < 256; i = i + 1) begin
      cpu_addr = i[8:0];
      @(posedge clk);
      @(posedge clk);
      if (cpu_data !== rom[i]) begin
        errors = errors + 1;
        if (errors <= 8) $display("case2 MISMATCH @%0d: got %02x exp %02x", i, cpu_data, rom[i]);
      end
    end

    if (errors == 0) $display("tb_edid_i2c_err: PASS (NAK->err abort; E-DDC NAK keeps blocks 0-1)");
    else begin
      $display("tb_edid_i2c_err: FAIL (%0d checks)", errors);
      $fatal(1);
    end
    $finish;
  end

  initial begin
    #50_000_000;
    $display("tb_edid_i2c_err: TIMEOUT");
    $fatal(1);
  end
endmodule

`default_nettype wire

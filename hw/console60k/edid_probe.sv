// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
// Read-only DDC qualification: "EDID", status, then 512 unformatted bytes.
// Status[0]=valid, [1]=error. Send ASCII 'r' for another read. No CPU or printf
// participates in the data path; the host checks header, checksums and repeats.
module edid_probe (
    input  wire logic sys_clk,
    input  wire logic btn_rst_n,
    input  wire logic uart_rxd,
    output wire logic uart_txd,
    input  wire logic hpd,
    inout  wire       ddc_scl,
    inout  wire       ddc_sda
);
  logic [15:0] por = 0;
  logic rst_meta = 0, rst_sync = 0;
  always_ff @(posedge sys_clk) begin
    rst_meta <= btn_rst_n;
    rst_sync <= rst_meta;
    if (!rst_sync) por <= 0;
    else if (!(&por)) por <= por + 1'b1;
  end
  wire nrst = &por;
  logic start, busy, valid, done, err;
  logic [8:0] address;
  logic [7:0] value;
  wire scl_release, sda_low;
  assign ddc_scl = scl_release ? 1'bz : 1'b0;
  assign ddc_sda = sda_low ? 1'b0 : 1'bz;
  edid_i2c #(
      .CLK_HZ(50_000_000),
      .I2C_HZ(100_000)
  ) u_edid (
      .clk     (sys_clk),
      .rst_n   (nrst),
      .start   (start),
      .hpd     (hpd),
      .busy    (busy),
      .valid   (valid),
      .done    (done),
      .err     (err),
      .cpu_addr(address),
      .cpu_data(value),
      .scl_o   (scl_release),
      .sda_oe  (sda_low),
      .sda_in  (ddc_sda)
  );
  wire sample_tick, bit_tick, tx_ready, rx_stb;
  wire [7:0] rx_data;
  wire [2:0] rx_err;
  logic [7:0] tx_data;
  logic tx_we;
  uart_baud_dds #(
      .CLK_HZ(50_000_000)
  ) u_baud (
      .clk_i        (sys_clk),
      .nrst_i       (nrst),
      .divisor_i    (16'd1),
      .resync_i     (1'b0),
      .samp16_tick_o(sample_tick),
      .bit_tick_o   (bit_tick)
  );
  uart_tx_core u_tx (
      .clk_i         (sys_clk),
      .nrst_i        (nrst),
      .baud_tick_i   (bit_tick),
      .data_i        (tx_data),
      .we_i          (tx_we),
      .word_len_i    (2'd3),
      .parity_en_i   (1'b0),
      .parity_even_i (1'b0),
      .parity_stick_i(1'b0),
      .stop2_i       (1'b0),
      .break_i       (1'b0),
      .ready_o       (tx_ready),
      .tx_idle_o     (),
      .txd_o         (uart_txd)
  );
  uart_rx_core u_rx (
      .clk_i         (sys_clk),
      .nrst_i        (nrst),
      .samp16_tick_i (sample_tick),
      .rxd_i         (uart_rxd),
      .word_len_i    (2'd3),
      .parity_en_i   (1'b0),
      .parity_even_i (1'b0),
      .parity_stick_i(1'b0),
      .data_o        (rx_data),
      .err_o         (rx_err),
      .parity_bit_o  (),
      .stb_o         (rx_stb)
  );
  typedef enum logic [2:0] {
    Idle,
    Header,
    Wait1,
    Wait2,
    Data
  } state_t;
  state_t state;
  logic [2:0] prefix;
  logic [7:0] status;
  always_comb begin
    tx_we   = (state == Header || state == Data);
    tx_data = value;
    if (state == Header) begin
      case (prefix)
        0: tx_data = "E";
        1: tx_data = "D";
        2: tx_data = "I";
        3: tx_data = "D";
        default: tx_data = status;
      endcase
    end
  end
  always_ff @(posedge sys_clk) begin
    start <= 0;
    if (!nrst) begin
      state   <= Idle;
      prefix  <= 0;
      address <= 0;
      status  <= 0;
    end else begin
      case (state)
        Idle: begin
          if (rx_stb && rx_data == "r" && rx_err == 0 && !busy) start <= 1;
          if (done) begin
            status <= {6'd0, err, valid};
            prefix <= 0;
            state  <= Header;
          end
        end
        Header:
        if (tx_ready) begin
          if (prefix == 4) begin
            address <= 0;
            state   <= Wait1;
          end else prefix <= prefix + 1'b1;
        end
        Wait1:   state <= Wait2;
        Wait2:   state <= Data;
        Data:
        if (tx_ready) begin
          if (address == 511) state <= Idle;
          else begin
            address <= address + 1'b1;
            state   <= Wait1;
          end
        end
        default: state <= Idle;
      endcase
    end
  end
endmodule

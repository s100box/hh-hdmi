// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// hdmi_cec.sv  --  HDMI-CEC follower: remote keys to a parameterized key map,
// ACK, One Touch Play and OSD name.
//
// A minimal Consumer Electronics Control device on the single-wire CEC bus. It:
//   * receives CEC frames (start bit + N x {8 data, EOM, ACK} blocks), ACKing
//     blocks addressed to our Logical Address (OUR_ADDR);
//   * dumps each received frame as hex over the debug UART for verification;
//   * decodes <User Control Pressed>/<Released> (opcodes $44/$45) through the
//     KEY_UI map into the `key` outputs, with a synthesized hold (a Pressed
//     re-arms a one-shot, so a key stays asserted between the TV's
//     auto-repeats);
//   * sends One Touch Play (<Image View On> + <Active Source>) BOOT_CYC after
//     reset so the TV switches its input to us;
//   * replies to <Give OSD Name> ($46) with <Set OSD Name> ($47) OSD_NAME;
//   * latches <Standby> ($36) on `cec_standby` until a remote key or reset.
//
// The key map is the consumer's: KEY_UI holds one CEC UI Command code (CEC Table
// 27) per output, key[i] following KEY_UI[8*i +: 8]. A key is a held level by
// default: it rises on <User Control Pressed>, falls on <User Control Released>
// or when the HOLD_CYC one-shot expires, and a Pressed of any code drops every
// other held key (a TV remote sends one key at a time). KEY_PULSE[i] = 1 makes
// key[i] a one-clock pulse per Pressed instead, for a console switch or a
// menu action. The defaults map Select and the four directions.
//
// OSD_NAME is the <Set OSD Name> payload, 1 to 14 ASCII characters as a string
// literal; its length is taken from the characters present.
//
// CEC is open-drain (idle high via pull-up): `cec_oe` drives the line low,
// `cec_in` samples it. All bit timings are parameters (clocks) so the gate can
// shrink them; the defaults are the spec values at 75 MHz. Bits are classified by
// their low-time: start > ~2.6 ms; data '1' low < ~1.05 ms, '0' otherwise.
//----------------------------------------------------------------------------
`default_nettype none

module hdmi_cec #(
    parameter int unsigned START_LOW = 277500,  // 3.7 ms @75 MHz
    parameter int unsigned START_PER = 337500,  // 4.5 ms (start-bit total)
    parameter int unsigned ZERO_LOW = 112500,  // 1.5 ms
    parameter int unsigned ONE_LOW = 45000,  // 0.6 ms
    parameter int unsigned BIT_PER = 180000,  // 2.4 ms
    parameter int unsigned HOLD_CYC = 15000000,  // ~200 ms synthesized key hold
    parameter int unsigned BOOT_CYC = 75000000,  // ~1 s after reset -> One Touch Play
    parameter logic [3:0] OUR_ADDR = 4'd4,  // Playback Device 1
    parameter logic [15:0] PHYS_ADDR = 16'h1000,  // assumed physical address (1.0.0.0)
    // The device name the TV lists: <Set OSD Name> payload, 1..14 characters.
    parameter logic [111:0] OSD_NAME = "hh-hdmi",
    // The key map: key[i] follows CEC UI command KEY_UI[8*i +: 8]; KEY_PULSE[i] = 1
    // makes it a one-clock pulse per Pressed instead of a held level.
    parameter int unsigned NKEYS = 5,
    parameter logic [8*NKEYS-1:0] KEY_UI = {8'h04, 8'h03, 8'h02, 8'h01, 8'h00},  // R,L,D,U,Sel
    parameter logic [NKEYS-1:0] KEY_PULSE = '0
) (
    input  wire logic             clk,
    input  wire logic             rst_n,
    // CEC line (open-drain).
    output logic                  cec_oe,       // 1 = drive low
    input  wire logic             cec_in,
    // 1 when the TV told us to go to standby (cleared by reset or a remote key).
    output logic                  cec_standby,
    // Decoded remote keys (active-high), one per KEY_UI entry.
    output logic      [NKEYS-1:0] key,
    // Debug UART.
    output logic      [      7:0] uart_data,
    output logic                  uart_we,
    input  wire logic             uart_ready
);

  localparam int unsigned START_THRESH = (ZERO_LOW + START_LOW) / 2;  // > => start
  localparam int unsigned DATA_THRESH = (ONE_LOW + ZERO_LOW) / 2;  // < => '1'

  // Counter widths follow the timing parameters. The low-time counter saturates
  // at all ones, at or above START_PER and so above every threshold; the
  // transmit bit timer counts to the longer of the two periods.
  // The constant functions below run only at elaboration, so a coverage
  // tool would count their bodies as never executed.
  // verilator coverage_off
  function automatic int unsigned width_of(input int unsigned max_value);
    return (max_value == 0) ? 1 : $clog2(max_value + 1);
  endfunction
  localparam int unsigned T_W = width_of(START_PER);
  localparam int unsigned TXT_W = width_of((START_PER > BIT_PER) ? START_PER : BIT_PER);
  localparam int unsigned HOLD_W = width_of(HOLD_CYC);
  localparam int unsigned BOOT_W = width_of(BOOT_CYC);

  // ── OSD name: left-align the string literal and count its characters ──────
  // A string literal sits right-justified in its parameter; osd_align moves it to
  // the top byte so the name goes out first character first.
  function automatic logic [111:0] osd_align(input logic [111:0] s);
    logic [111:0] r;
    r = s;
    for (int k = 0; k < 14; k++) if (r[111:104] == 8'h00) r = r << 8;
    return r;
  endfunction
  function automatic int unsigned osd_count(input logic [111:0] s);
    int unsigned n;
    n = 0;
    for (int k = 0; k < 14; k++) if (s[111-8*k-:8] != 8'h00) n = n + 1;
    return n;
  endfunction
  localparam logic [111:0] OSD_L = osd_align(OSD_NAME);
  localparam int unsigned OSD_LEN = osd_count(OSD_L);
  // verilator coverage_on

  // ── Line edge detect + low-time measurement ──────────────────────────────
  // CEC is asynchronous to clk. Only the second synchronizer stage enters
  // the edge detector; low-time measurements retain one-clock quantization.
  (* ASYNC_REG = "TRUE" *) logic cec_meta, cec_sync;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cec_meta <= 1'b1;
      cec_sync <= 1'b1;
    end else begin
      cec_meta <= cec_in;
      cec_sync <= cec_meta;
    end
  end
  logic           cec_d;
  logic [T_W-1:0] t;  // clocks since the last falling edge, saturating
  wire            fall = cec_d & ~cec_sync;
  wire            rise = ~cec_d & cec_sync;

  // ── Receiver ──────────────────────────────────────────────────────────────
  logic rx_active, eom, ack_blk, ack_drive;
  logic [3:0] bitc;  // 0..9 within a block (8 data, EOM, ACK)
  logic [7:0] rxbyte;
  logic [3:0] blkidx;  // received-byte index in this frame
  logic [7:0] frame                                                        [16];
  logic       frame_done;  // 1-cycle pulse: a complete frame is in frame[]
  logic [4:0] frame_len;  // 1..16 blocks

  // ── UART dump of the last frame ───────────────────────────────────────────
  logic       dumping;
  logic [4:0] d_idx;
  logic [1:0] d_sub;
  function automatic logic [7:0] hexc(input logic [3:0] n);
    hexc = (n < 4'd10) ? (8'h30 + {4'd0, n}) : (8'h41 + {4'd0, n - 4'd10});
  endfunction

  // ── Transmitter ───────────────────────────────────────────────────────────
  // Sends three message kinds: the Set OSD Name reply, and the One Touch Play
  // pair Image View On + Active Source (broadcast) at power-up so the TV switches
  // its input to us. Each is a pending request of its own (osd_pend, boot_st),
  // and one arbiter starts the next frame when the line is free, the reply first,
  // so a request arriving while another waits is never lost. A CEC frame is at
  // most 16 blocks: header + opcode + 14 operands.
  localparam int TXN = 16;
  logic [       7:0] txbuf                                           [TXN];
  logic [       4:0] txlen;
  logic              osd_pend;  // a <Give OSD Name> awaits its reply
  logic              tx_busy;
  logic [       3:0] tx_byte;  // which byte
  logic [       3:0] tx_bit;  // 0..9 within a byte
  logic              tx_ph;  // 0 low, 1 high
  logic [ TXT_W-1:0] tx_t;
  logic              tx_drive;

  // One Touch Play boot sequencer.
  logic [BOOT_W-1:0] boot_cnt;
  logic [       1:0] boot_st;  // 0 wait, 1 IVO due, 2 AS due, 3 done

  assign cec_oe = ack_drive | tx_drive;

  // Current TX bit value: bits 1..8 = data (MSB first), 9 = EOM, 10 = ACK slot.
  wire [3:0] tx_eom_byte = 4'(txlen - 5'd1);
  wire       tx_curbit = (tx_bit <= 4'd8) ? txbuf[tx_byte][4'd8 - tx_bit]
                       : (tx_bit == 4'd9) ? (tx_byte == tx_eom_byte) : 1'b1;

  // ── Synthesized-hold key state ────────────────────────────────────────────
  logic [HOLD_W-1:0] hold;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cec_d       <= 1'b1;
      t           <= '0;
      rx_active   <= 1'b0;
      eom         <= 1'b0;
      ack_blk     <= 1'b0;
      ack_drive   <= 1'b0;
      bitc        <= 4'd0;
      rxbyte      <= 8'd0;
      blkidx      <= 4'd0;
      frame_done  <= 1'b0;
      frame_len   <= 5'd0;
      dumping     <= 1'b0;
      d_idx       <= 5'd0;
      d_sub       <= 2'd0;
      uart_we     <= 1'b0;
      uart_data   <= 8'd0;
      osd_pend    <= 1'b0;
      tx_busy     <= 1'b0;
      tx_byte     <= 4'd0;
      tx_bit      <= 4'd0;
      tx_ph       <= 1'b0;
      tx_t        <= '0;
      tx_drive    <= 1'b0;
      txlen       <= 5'd0;
      boot_cnt    <= '0;
      boot_st     <= 2'd0;
      cec_standby <= 1'b0;
      key         <= '0;
      hold        <= '0;
    end else begin
      cec_d      <= cec_sync;
      frame_done <= 1'b0;
      uart_we    <= 1'b0;
      key        <= key & ~KEY_PULSE;  // pulse keys are momentary

      // Low-time counter (saturating).
      if (fall) t <= '0;
      else if (t != '1) t <= t + 1'b1;

      // Release the ACK pulse after one '0' low-time.
      if (ack_drive && t >= T_W'(ZERO_LOW)) ack_drive <= 1'b0;

      // Begin driving the ACK bit low at its falling edge (if addressed).
      if (fall && rx_active && bitc == 4'd9 && ack_blk && !tx_busy) ack_drive <= 1'b1;

      // ---- RX bit classification on the rising edge (idle while transmitting) ----
      if (rise && !tx_busy) begin
        if (t >= T_W'(START_THRESH)) begin
          rx_active <= 1'b1;
          bitc      <= 4'd0;
          rxbyte    <= 8'd0;
          blkidx    <= 4'd0;
          eom       <= 1'b0;
        end else if (rx_active) begin
          if (bitc < 4'd8) begin
            rxbyte <= {rxbyte[6:0], (t < T_W'(DATA_THRESH))};
            bitc   <= bitc + 4'd1;
          end else if (bitc == 4'd8) begin
            eom           <= (t < T_W'(DATA_THRESH));
            bitc          <= 4'd9;
            frame[blkidx] <= rxbyte;
            // The destination LA is the low nibble of block 0's header.
            if (blkidx == 4'd0) ack_blk <= (rxbyte[3:0] == OUR_ADDR);
          end else begin  // bitc == 9: ACK bit finished
            if (eom) begin
              rx_active  <= 1'b0;
              frame_done <= 1'b1;
              frame_len  <= {1'b0, blkidx} + 5'd1;
            end else if (blkidx == 4'd15) begin
              // No EOM at the protocol's 16-block limit: discard this frame
              // and wait for a new START instead of wrapping frame[].
              rx_active <= 1'b0;
              ack_blk   <= 1'b0;
              bitc      <= 4'd0;
            end else begin
              bitc   <= 4'd0;
              blkidx <= blkidx + 4'd1;
            end
          end
        end
      end

      // ---- Synthesized hold: drop the held keys when the one-shot expires.
      //      Before the dispatch, so a Pressed landing on the same clock wins. ----
      if (hold != '0) begin
        hold <= hold - 1'b1;
        if (hold == HOLD_W'(1)) key <= '0;
      end

      // ---- Dispatch a complete frame ----
      if (frame_done) begin
        dumping <= 1'b1;
        d_idx   <= 5'd0;
        d_sub   <= 2'd0;
        // <Standby> ($36), directed or broadcast: the TV is powering down.
        // A poll contains only the header. Unwritten array entries retain
        // earlier frames, so validate length before reading opcode/operands.
        if (frame_len >= 5'd2 && frame[1] == 8'h36 &&
            (frame[0][3:0] == OUR_ADDR || frame[0][3:0] == 4'hF))
          cec_standby <= 1'b1;
        if (frame_len >= 5'd2 && frame[0][3:0] == OUR_ADDR) begin
          case (frame[1])
            8'h44: begin  // User Control Pressed: operand = UI command
              if (frame_len >= 5'd3) begin
                key         <= '0;
                cec_standby <= 1'b0;  // a key wakes us
                for (int i = 0; i < NKEYS; i++) if (frame[2] == KEY_UI[8*i+:8]) key[i] <= 1'b1;
                hold <= HOLD_W'(HOLD_CYC);
              end
            end
            8'h45: begin  // User Control Released: drop the held keys
              key  <= '0;
              hold <= '0;
            end
            8'h46:   osd_pend <= 1'b1;  // Give OSD Name -> reply
            default: ;
          endcase
        end
      end

      // ---- One Touch Play: ~BOOT_CYC after reset, send Image View On then
      //      Active Source so the TV switches its input to us. ----
      if (boot_st == 2'd0) begin
        if (boot_cnt >= BOOT_W'(BOOT_CYC)) boot_st <= 2'd1;
        else boot_cnt <= boot_cnt + 1'b1;
      end

      // ---- UART dump: "hh hh ... \n" for the received frame ----
      if (dumping && uart_ready && !uart_we) begin
        if (d_idx < frame_len) begin
          case (d_sub)
            2'd0: begin
              uart_data <= hexc(frame[d_idx][7:4]);
              uart_we   <= 1'b1;
              d_sub     <= 2'd1;
            end
            2'd1: begin
              uart_data <= hexc(frame[d_idx][3:0]);
              uart_we   <= 1'b1;
              d_sub     <= 2'd2;
            end
            default: begin
              uart_data <= 8'h20;
              uart_we   <= 1'b1;
              d_sub     <= 2'd0;
              d_idx     <= d_idx + 5'd1;
            end
          endcase
        end else begin
          uart_data <= 8'h0A;
          uart_we   <= 1'b1;
          dumping   <= 1'b0;
        end
      end

      // ---- TX: when the line is free, build the next pending message (the OSD
      //      reply first, then One Touch Play in order), then shift it out ----
      if (!tx_busy && !rx_active && (osd_pend || boot_st == 2'd1 || boot_st == 2'd2)) begin
        if (osd_pend) begin  // Set OSD Name OSD_NAME -> TV
          txbuf[0] <= {OUR_ADDR, 4'd0};
          txbuf[1] <= 8'h47;
          for (int i = 0; i < 14; i++) txbuf[2+i] <= OSD_L[111-8*i-:8];
          txlen    <= 5'(2 + OSD_LEN);
          osd_pend <= 1'b0;
        end else if (boot_st == 2'd1) begin  // Image View On -> TV (dest 0)
          txbuf[0] <= {OUR_ADDR, 4'd0};
          txbuf[1] <= 8'h04;
          txlen    <= 5'd2;
          boot_st  <= 2'd2;
        end else begin  // Active Source (broadcast) + phys addr
          txbuf[0] <= {OUR_ADDR, 4'hF};
          txbuf[1] <= 8'h82;
          txbuf[2] <= PHYS_ADDR[15:8];
          txbuf[3] <= PHYS_ADDR[7:0];
          txlen    <= 5'd4;
          boot_st  <= 2'd3;
        end
        tx_busy  <= 1'b1;
        tx_byte  <= 4'd0;
        tx_bit   <= 4'd0;
        tx_ph    <= 1'b0;
        tx_t     <= '0;
        tx_drive <= 1'b1;  // start bit: pull low
      end else if (tx_busy) begin
        tx_t <= tx_t + 1'b1;
        if (tx_byte == 4'd0 && tx_bit == 4'd0) begin
          // Start bit: low for START_LOW, then high to START_PER.
          if (!tx_ph && tx_t >= TXT_W'(START_LOW)) begin
            tx_drive <= 1'b0;
            tx_ph    <= 1'b1;
          end else if (tx_ph && tx_t >= TXT_W'(START_PER)) begin
            tx_t     <= '0;
            tx_ph    <= 1'b0;
            tx_bit   <= 4'd1;
            tx_drive <= 1'b1;  // first data bit low
          end
        end else begin
          // Data (1..8), EOM (9), ACK (10). ACK is sent as '1' (release; we don't
          // verify the follower's ack — single-initiator bring-up).
          if (!tx_ph) begin
            // low portion: ONE_LOW for '1', ZERO_LOW for '0'.
            if (tx_t >= (tx_curbit ? TXT_W'(ONE_LOW) : TXT_W'(ZERO_LOW))) begin
              tx_drive <= 1'b0;
              tx_ph    <= 1'b1;
            end
          end else if (tx_t >= TXT_W'(BIT_PER)) begin
            tx_t  <= '0;
            tx_ph <= 1'b0;
            if (tx_bit < 4'd10) begin
              tx_bit   <= tx_bit + 4'd1;
              tx_drive <= 1'b1;  // next bit's low starts
            end else if (tx_byte == tx_eom_byte) begin
              tx_busy  <= 1'b0;
              tx_drive <= 1'b0;  // message done
            end else begin
              tx_byte  <= tx_byte + 4'd1;
              tx_bit   <= 4'd1;
              tx_drive <= 1'b1;
            end
          end
        end
      end
    end
  end

endmodule

`default_nettype wire

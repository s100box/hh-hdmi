// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// edid_i2c.sv  --  DDC/E-DDC EDID reader with a CPU-readable byte window.
//
// I2C master that reads the connected HDMI sink's EDID over the DDC channel and
// stores it in a dual-port BSRAM. Rather than parsing a few fields in hardware, this
// block exposes the *raw* EDID bytes to a CPU so firmware can do the full analysis.
//
// It reads up to FOUR 128-byte blocks (512 bytes) so it captures a CEA-861 block
// that lives beyond block 1 (e.g. an LG panel whose block 1 is a Block Map or
// DisplayID and whose CEA block is block 2). Blocks are grouped into 256-byte
// E-DDC segments; segment 0 (blocks 0-1) reads with a plain DDC transfer, and if
// the block-0 extension count (byte 126) says there are more than two blocks, a
// second segment is read after writing the E-DDC segment pointer (0x60).
//
// DDC sequence, segment 0:
//   START . A0(wr) . 00(offset) . RSTART . A1(rd) . read 256 (NACK last) . STOP
// E-DDC sequence, segment 1 (only if byte 126 >= 2):
//   START . 60(wr) . 01(seg) . RSTART . A0(wr) . 00 . RSTART . A1(rd)
//         . read 256 (NACK last) . STOP
//
// I2C lines are open-drain: SCL/SDA are released (Hi-Z, pulled high by the board)
// or actively driven low. The top wraps scl_o / sda_oe into tristate pads.
//   scl_o  : 1 = release (high), 0 = drive low
//   sda_oe : 1 = drive low,      0 = release (high)
//   sda_in : asynchronous SDA pad, synchronized before ACK/data sampling
//
// A read auto-starts after reset, on a rising edge of `hpd` (display hot-plug),
// and whenever `start` is pulsed; a trigger while `busy` is ignored. `busy` is
// high during a transfer. `valid` is set when a read completes without a
// base-EDID NAK and cleared by one; checking the header (00 FF..FF 00) and the
// block checksums is left to the CPU.
//
// Error handling: every write-byte ACK is checked. A NAK while addressing the base
// EDID (segment 0) means there is no readable sink at that address (unplugged /
// dead EEPROM / wrong address) -- the transfer aborts cleanly (STOP), `valid` is
// left 0, and `err` is raised so firmware stops rather than decoding garbage. A NAK
// on the E-DDC segment-pointer path (segment 1) means the sink lacks E-DDC; that
// aborts too but keeps `valid` (blocks 0-1 already read) and does NOT flag `err`.
// The bit engine is open-loop (it drives SCL itself and never waits on the bus), so
// a stuck slave cannot hang it -- no bus timeout is needed. `err` clears on each
// (re)start.
//----------------------------------------------------------------------------
`default_nettype none

module edid_i2c #(
    parameter int unsigned CLK_HZ = 50_000_000,  // edid_i2c clock (board oscillator)
    parameter int unsigned I2C_HZ = 100_000      // DDC bit rate (standard-mode)
) (
    input wire logic clk,
    input wire logic rst_n,

    // Control / status (CPU side).
    input  wire logic start,  // 1-clk pulse: (re)read the EDID
    input  wire logic hpd,    // sink hot-plug detect (async ok)
    output logic      busy,
    output logic      valid,  // last read completed without a base-EDID NAK
    output logic      done,   // 1-clk pulse at end of a read
    output logic      err,    // last read aborted on a base-EDID NAK

    // CPU read window into the 512-byte EDID store (registered, 1-clk latency).
    input  wire logic [8:0] cpu_addr,
    output logic      [7:0] cpu_data,

    // Open-drain DDC pads.
    output logic      scl_o,
    output logic      sda_oe,
    input  wire logic sda_in
);

  // Quarter-bit tick: four phases make one SCL period.
  localparam int unsigned QDIV = (CLK_HZ / I2C_HZ) / 4;

  // The input pipeline must settle before phase 2 samples ACK/data. Four
  // clocks per quarter leave margin for its two registers; board timing must
  // also include the sink's data-valid delay, level shifters and pull-up rise.
  initial begin
    if (QDIV < 4) $fatal(1, "edid_i2c requires CLK_HZ >= 16 * I2C_HZ");
  end

  (* ASYNC_REG = "TRUE" *) logic sda_meta, sda_sync;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      sda_meta <= 1'b1;
      sda_sync <= 1'b1;
    end else begin
      sda_meta <= sda_in;
      sda_sync <= sda_meta;
    end
  end

  // ---- 512-byte EDID store (write: I2C side, read: CPU side) --------------
  (* syn_ramstyle = "block_ram" *)logic [7:0] edid    [512];
  logic [8:0] wr_addr;
  logic [7:0] wr_data;
  logic       wr_en;
  always_ff @(posedge clk) if (wr_en) edid[wr_addr] <= wr_data;
  always_ff @(posedge clk) cpu_data <= edid[cpu_addr];

  // ---- Hot-plug edge + start trigger --------------------------------------
  (* ASYNC_REG = "TRUE" *) logic hpd_s0 = 1'b0, hpd_s1 = 1'b0;
  logic hpd_q = 1'b0;
  always_ff @(posedge clk) begin
    if (!rst_n) {hpd_s0, hpd_s1, hpd_q} <= 3'b000;
    else {hpd_q, hpd_s1, hpd_s0} <= {hpd_s1, hpd_s0, hpd};
  end
  wire hpd_rise = hpd_s1 & ~hpd_q;

  // ---- I2C bit engine -----------------------------------------------------
  // ST_WR_SEG/ST_WR_SEGNUM write the E-DDC segment pointer (0x60 + seg#) and
  // ST_RSTART2 is the repeated-start into A0 that must follow it (no STOP in
  // between, else the segment pointer resets).
  typedef enum logic [3:0] {
    ST_IDLE,
    ST_START,
    ST_WR_SEG,
    ST_WR_SEGNUM,
    ST_RSTART2,
    ST_WR_A0,
    ST_WR_OFF,
    ST_RSTART,
    ST_WR_A1,
    ST_RD,
    ST_STOP,
    ST_DONE
  } state_t;
  state_t                      state;

  logic   [$clog2(QDIV+1)-1:0] qcnt;  // quarter-bit divider
  logic   [               1:0] phase;  // 0..3 within an SCL bit
  logic   [               3:0] bitno;  // bit index within a byte (8..1) / ack
  logic   [               7:0] shifter;  // tx/rx shift register
  logic                        ack_in;  // captured ACK (0 = acked)
  logic   [               7:0] rd_count;  // byte index within this segment (0..255)
  logic                        seg;  // current E-DDC segment (0 or 1)
  // Block 0's byte 126 (the extension count) is 2 or more: blocks 2-3 exist, so
  // a second segment follows.
  logic                        need_seg1;
  logic scl, sda_drv;  // line drivers (1 = release/high)

  wire q_tick = (qcnt == QDIV[$clog2(QDIV+1)-1:0] - 1);
  wire last_byte = (rd_count == 8'd255);

  assign scl_o  = scl;
  assign sda_oe = ~sda_drv;  // sda_drv 0 => drive low
  assign busy   = (state != ST_IDLE) && (state != ST_DONE);

  // The bytes the write states shift out.
  localparam logic [7:0] BYTE_SEG = 8'h60;  // E-DDC segment pointer, write
  localparam logic [7:0] BYTE_A0 = 8'hA0;  // EDID EEPROM, write
  localparam logic [7:0] BYTE_OFF = 8'h00;  // word offset 0 (within the segment)
  localparam logic [7:0] BYTE_A1 = 8'hA1;  // EDID EEPROM, read

  // SYNCHRONOUS RESET, both blocks. wr_addr addresses the EDID buffer BRAM and
  // wr_en becomes its enable, and a block RAM address or enable driven by an
  // asynchronously-reset register is Vivado REQP-1839/1840: the write can land at
  // an indeterminate address when the reset asserts, and static timing does not
  // examine it. The caller must provide a running clock and hold rst_n low
  // across a rising edge before using the control/status or memory interface.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state     <= ST_START;  // auto-read once after reset
      qcnt      <= '0;
      phase     <= 2'd0;
      bitno     <= 4'd0;
      shifter   <= 8'h00;
      ack_in    <= 1'b1;
      rd_count  <= 8'd0;
      seg       <= 1'b0;
      need_seg1 <= 1'b0;
      scl       <= 1'b1;
      sda_drv   <= 1'b1;
      wr_en     <= 1'b0;
      wr_addr   <= 9'h000;
      wr_data   <= 8'h00;
      done      <= 1'b0;
      valid     <= 1'b0;
      err       <= 1'b0;
    end else begin
      done  <= 1'b0;
      wr_en <= 1'b0;

      // Return to idle unless a new non-busy trigger below starts a read.
      // ST_DONE advertises !busy, so a trigger in that cycle must win.
      if (state == ST_DONE) state <= ST_IDLE;

      // Re-arm triggers (not while a transfer is running). Start over at segment 0.
      if (!busy && (start || hpd_rise)) begin
        state     <= ST_START;
        rd_count  <= 8'd0;
        seg       <= 1'b0;
        need_seg1 <= 1'b0;
        phase     <= 2'd0;
        qcnt      <= '0;
        bitno     <= 4'd0;
        err       <= 1'b0;
      end

      // Advance the quarter-bit divider; act only on q_tick.
      if (state == ST_IDLE || state == ST_DONE) begin
        qcnt <= '0;
      end else if (!q_tick) begin
        qcnt <= qcnt + 1'b1;
      end else begin
        qcnt  <= '0;
        phase <= phase + 2'd1;

        case (state)
          // START: SDA high->low while SCL high, then SCL low. The first byte is
          // the segment pointer (0x60) for segment >0, else A0.
          ST_START: begin
            case (phase)
              2'd0: begin
                scl     <= 1'b1;
                sda_drv <= 1'b1;
              end
              2'd1: sda_drv <= 1'b0;  // SDA low, SCL still high
              2'd2: scl <= 1'b0;  // SCL low -> begin first byte
              default: begin  // 2'd3
                bitno <= 4'd8;
                if (!seg) begin
                  shifter <= BYTE_A0;
                  state   <= ST_WR_A0;
                end else begin
                  shifter <= BYTE_SEG;
                  state   <= ST_WR_SEG;
                end
              end
            endcase
          end

          // Repeated start into A0 (used after the segment-pointer write).
          ST_RSTART2: begin
            case (phase)
              2'd0: begin
                scl     <= 1'b0;
                sda_drv <= 1'b1;
              end  // release SDA, SCL low
              2'd1: scl <= 1'b1;  // SCL high with SDA high
              2'd2: sda_drv <= 1'b0;  // SDA falls -> repeated start
              default: begin  // 2'd3
                scl     <= 1'b0;
                shifter <= BYTE_A0;
                bitno   <= 4'd8;
                state   <= ST_WR_A0;
              end
            endcase
          end

          ST_RSTART: begin
            case (phase)
              2'd0: begin
                scl     <= 1'b0;
                sda_drv <= 1'b1;
              end  // release SDA, SCL low
              2'd1: scl <= 1'b1;  // SCL high with SDA high
              2'd2: sda_drv <= 1'b0;  // SDA falls -> repeated start
              default: begin  // 2'd3
                scl     <= 1'b0;
                shifter <= BYTE_A1;
                bitno   <= 4'd8;
                state   <= ST_WR_A1;
              end
            endcase
          end

          // Write a byte MSB-first, then sample ACK on the 9th bit.
          ST_WR_SEG, ST_WR_SEGNUM, ST_WR_A0, ST_WR_OFF, ST_WR_A1: begin
            if (bitno != 4'd0) begin
              case (phase)
                2'd0: begin
                  scl     <= 1'b0;
                  sda_drv <= shifter[7];
                end
                2'd1: scl <= 1'b1;
                2'd2: ;  // slave samples
                default: begin  // 2'd3
                  scl     <= 1'b0;
                  shifter <= {shifter[6:0], 1'b0};
                  bitno   <= bitno - 4'd1;
                end
              endcase
            end else begin
              // ACK bit: release SDA, clock once, sample. ack_in 0 = ACK, 1 = NAK.
              case (phase)
                2'd0: begin
                  scl     <= 1'b0;
                  sda_drv <= 1'b1;
                end
                2'd1: scl <= 1'b1;
                2'd2: ack_in <= sda_sync;
                default: begin  // 2'd3
                  scl   <= 1'b0;
                  phase <= 2'd0;
                  if (ack_in) begin
                    // NAK: no slave acknowledged. Abort to STOP. A base-EDID (seg 0)
                    // NAK is a real failure -> flag err (valid<=0 at STOP); a seg-1
                    // E-DDC NAK just means no E-DDC, so keep the blocks 0-1 read.
                    if (!seg) err <= 1'b1;
                    state <= ST_STOP;
                  end else begin
                    case (state)
                      ST_WR_SEG: begin
                        shifter <= {7'd0, seg};
                        bitno   <= 4'd8;
                        state   <= ST_WR_SEGNUM;
                      end
                      ST_WR_SEGNUM: state <= ST_RSTART2;
                      ST_WR_A0: begin
                        shifter <= BYTE_OFF;
                        bitno   <= 4'd8;
                        state   <= ST_WR_OFF;
                      end
                      ST_WR_OFF:    state <= ST_RSTART;
                      default: begin
                        bitno    <= 4'd8;
                        rd_count <= 8'd0;
                        state    <= ST_RD;
                      end
                    endcase
                  end
                end
              endcase
            end
          end

          // Read a byte MSB-first, then drive ACK (or NACK on the last byte).
          ST_RD: begin
            if (bitno != 4'd0) begin
              case (phase)
                2'd0: begin
                  scl     <= 1'b0;
                  sda_drv <= 1'b1;
                end  // release for slave
                2'd1: scl <= 1'b1;
                2'd2: shifter <= {shifter[6:0], sda_sync};
                default: begin  // 2'd3
                  scl   <= 1'b0;
                  bitno <= bitno - 4'd1;
                end
              endcase
            end else begin
              // ACK/NACK phase: master drives SDA.
              case (phase)
                2'd0: begin
                  scl     <= 1'b0;
                  sda_drv <= last_byte ? 1'b1 : 1'b0;
                end
                2'd1: scl <= 1'b1;
                2'd2: ;
                default: begin  // 2'd3
                  scl     <= 1'b0;
                  wr_en   <= 1'b1;  // commit the received byte
                  wr_addr <= {seg, rd_count};
                  wr_data <= shifter;
                  // Byte 126 of block 0 is the extension count; STOP reads it to
                  // decide on segment 1.
                  if (!seg && rd_count == 8'd126) need_seg1 <= (shifter >= 8'd2);
                  if (last_byte) begin
                    state <= ST_STOP;
                  end else begin
                    rd_count <= rd_count + 8'd1;
                    bitno    <= 4'd8;
                  end
                  phase <= 2'd0;
                end
              endcase
            end
          end

          // STOP: SDA low->high while SCL high. Then either start segment 1 or finish.
          ST_STOP: begin
            case (phase)
              2'd0: begin
                scl     <= 1'b0;
                sda_drv <= 1'b0;
              end
              2'd1: scl <= 1'b1;
              2'd2: sda_drv <= 1'b1;  // SDA rises -> stop
              default: begin  // 2'd3
                if (!seg && need_seg1 && !err) begin
                  // Read blocks 2-3 (segment 1) after re-issuing START + segment write.
                  seg      <= 1'b1;
                  rd_count <= 8'd0;
                  phase    <= 2'd0;
                  state    <= ST_START;
                end else begin
                  done  <= 1'b1;
                  // Flag a plausibly-valid read unless a base-EDID NAK aborted it
                  // (err). The full header check is left to the CPU.
                  valid <= ~err;
                  state <= ST_DONE;
                end
              end
            endcase
          end

          // A state code outside the enum (only a corrupted register gets
          // here): release the bus and finish, so the next trigger starts clean.
          default: begin
            scl     <= 1'b1;
            sda_drv <= 1'b1;
            state   <= ST_DONE;
          end
        endcase
      end
    end
  end

endmodule

`default_nettype wire

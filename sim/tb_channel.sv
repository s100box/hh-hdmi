// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//----------------------------------------------------------------------------
// tb_channel.sv -- one TMDS lane, every code it can emit, on all three lanes.
//
// Three hdmi_channel instances (CN 0, 1, 2) take the same inputs. Every output
// symbol is checked against an independent model written from the specs:
//
//   * video (mode 1): the DVI 1.0 8b/10b algorithm (transition minimization,
//     then DC balance against the running disparity), symbol for symbol; each
//     symbol also decodes back to its byte the way a sink decodes it, and the
//     running disparity measured on the wire stays inside the 5-bit signed
//     counter the lane keeps. The stimulus is all 256 bytes in order, runs of
//     0x00 and 0xFF that drive the disparity to both extremes, and random runs
//     of random length.
//   * the disparity restarts at 0 for every video period: each run follows a
//     non-video symbol, and the model starts it from 0.
//   * control (mode 0): the four HDMI 5.4.2 control symbols.
//   * video guard (mode 2): 1011001100 on lanes 0 and 2, 0100110011 on lane 1.
//   * data island (mode 3): the sixteen TERC4 codes.
//   * data island guard (mode 4): 0100110011 on lanes 1 and 2; on lane 0 the
//     TERC4 code of {1, 1, VSYNC, HSYNC} for each control value.
//   * modes 5, 6 and 7, which the encoder never sends, emit the control symbol.
//
// The output is registered: the symbol for the inputs presented before a
// clock edge appears after it.
//----------------------------------------------------------------------------
`default_nettype none

module tb_channel;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic [7:0] video_data = 8'd0;
  logic [3:0] island_data = 4'd0;
  logic [1:0] control_data = 2'd0;
  logic [2:0] mode = 3'd0;
  logic [9:0] tmds[3];

  for (genvar c = 0; c < 3; c++) begin : g_lane
    hdmi_channel #(
        .CN(c)
    ) u_ch (
        .clk_pix     (clk),
        .video_data  (video_data),
        .island_data (island_data),
        .control_data(control_data),
        .mode        (mode),
        .tmds        (tmds[c])
    );
  end

  integer errors = 0;
  integer checked = 0;
  integer n_video = 0;
  integer max_disp = 0;
  integer min_disp = 0;

  // ---- the spec model ---------------------------------------------------------
  function automatic integer ones8(input logic [7:0] v);
    ones8 = 0;
    for (int i = 0; i < 8; i++) ones8 += v[i];
  endfunction

  // DVI 1.0 Figure 3-5. cnt is the running disparity (#1 - #0 of the symbols
  // sent so far in this video period).
  task automatic tmds_encode(input logic [7:0] d, inout integer cnt, output logic [9:0] q);
    logic [8:0] qm;
    integer n1, n0;
    if (ones8(d) > 4 || (ones8(d) == 4 && d[0] == 1'b0)) begin
      qm[0] = d[0];
      for (int i = 1; i < 8; i++) qm[i] = ~(qm[i-1] ^ d[i]);
      qm[8] = 1'b0;
    end else begin
      qm[0] = d[0];
      for (int i = 1; i < 8; i++) qm[i] = qm[i-1] ^ d[i];
      qm[8] = 1'b1;
    end
    n1 = ones8(qm[7:0]);
    n0 = 8 - n1;
    if (cnt == 0 || n1 == n0) begin
      q[9]   = ~qm[8];
      q[8]   = qm[8];
      q[7:0] = qm[8] ? qm[7:0] : ~qm[7:0];
      if (qm[8] == 1'b0) cnt = cnt + (n0 - n1);
      else cnt = cnt + (n1 - n0);
    end else if ((cnt > 0 && n1 > n0) || (cnt < 0 && n0 > n1)) begin
      q[9]   = 1'b1;
      q[8]   = qm[8];
      q[7:0] = ~qm[7:0];
      cnt    = cnt + 2 * qm[8] + (n0 - n1);
    end else begin
      q[9]   = 1'b0;
      q[8]   = qm[8];
      q[7:0] = qm[7:0];
      cnt    = cnt - 2 * (~qm[8] & 1'b1) + (n1 - n0);
    end
  endtask

  // The sink's decode (DVI 1.0 Figure 3-6).
  function automatic logic [7:0] tmds_decode(input logic [9:0] q);
    logic [7:0] dp;
    logic [7:0] d;
    dp   = q[9] ? ~q[7:0] : q[7:0];
    d[0] = dp[0];
    for (int i = 1; i < 8; i++) d[i] = q[8] ? (dp[i] ^ dp[i-1]) : ~(dp[i] ^ dp[i-1]);
    return d;
  endfunction

  function automatic logic [9:0] ctrl_code(input logic [1:0] c);
    case (c)
      2'b00:   ctrl_code = 10'b1101010100;
      2'b01:   ctrl_code = 10'b0010101011;
      2'b10:   ctrl_code = 10'b0101010100;
      default: ctrl_code = 10'b1010101011;
    endcase
  endfunction

  function automatic logic [9:0] terc4_code(input logic [3:0] n);
    case (n)
      4'h0:    terc4_code = 10'b1010011100;
      4'h1:    terc4_code = 10'b1001100011;
      4'h2:    terc4_code = 10'b1011100100;
      4'h3:    terc4_code = 10'b1011100010;
      4'h4:    terc4_code = 10'b0101110001;
      4'h5:    terc4_code = 10'b0100011110;
      4'h6:    terc4_code = 10'b0110001110;
      4'h7:    terc4_code = 10'b0100111100;
      4'h8:    terc4_code = 10'b1011001100;
      4'h9:    terc4_code = 10'b0100111001;
      4'hA:    terc4_code = 10'b0110011100;
      4'hB:    terc4_code = 10'b1011000110;
      4'hC:    terc4_code = 10'b1010001110;
      4'hD:    terc4_code = 10'b1001110001;
      4'hE:    terc4_code = 10'b0101100011;
      default: terc4_code = 10'b1011000011;
    endcase
  endfunction

  // ---- one symbol: present the inputs, clock, check all three lanes ------------
  integer cnt[3] = '{0, 0, 0};
  integer wire_disp[3] = '{0, 0, 0};

  task automatic step(input logic [2:0] m, input logic [7:0] vd, input logic [3:0] isl,
                      input logic [1:0] cd);
    logic [9:0] want[3];
    @(negedge clk);
    mode         = m;
    video_data   = vd;
    island_data  = isl;
    control_data = cd;
    for (int c = 0; c < 3; c++) begin
      integer       cnt_c;
      logic   [9:0] want_c;
      cnt_c = cnt[c];
      tmds_encode(vd, cnt_c, want_c);
      case (m)
        3'd1: begin
          want[c] = want_c;
          cnt[c]  = cnt_c;
        end
        3'd2: want[c] = (c == 1) ? 10'b0100110011 : 10'b1011001100;
        3'd3: want[c] = terc4_code(isl);
        3'd4: want[c] = (c == 0) ? terc4_code({2'b11, cd}) : 10'b0100110011;
        default: want[c] = ctrl_code(cd);
      endcase
      if (m != 3'd1) cnt[c] = 0;
    end
    @(posedge clk);
    #1;
    for (int c = 0; c < 3; c++) begin
      checked++;
      if (tmds[c] !== want[c]) begin
        if (errors < 20)
          $display(
              "tb_channel: FAIL lane %0d mode %0d data %02h/%h/%b: got %b, want %b",
              c,
              m,
              vd,
              isl,
              cd,
              tmds[c],
              want[c]
          );
        errors++;
      end
      if (m == 3'd1) begin
        if (tmds_decode(tmds[c]) !== vd) begin
          if (errors < 20)
            $display(
                "tb_channel: FAIL lane %0d: %b decodes to %02h, sent %02h",
                c,
                tmds[c],
                tmds_decode(
                    tmds[c]
                ),
                vd
            );
          errors++;
        end
        wire_disp[c] = wire_disp[c] + 2 * ($countones(tmds[c])) - 10;
        if (wire_disp[c] > max_disp) max_disp = wire_disp[c];
        if (wire_disp[c] < min_disp) min_disp = wire_disp[c];
        if (wire_disp[c] > 15 || wire_disp[c] < -16) begin
          if (errors < 20)
            $display(
                "tb_channel: FAIL lane %0d: running disparity %0d leaves the counter",
                c,
                wire_disp[c]
            );
          errors++;
        end
      end else wire_disp[c] = 0;
    end
    if (m == 3'd1) n_video++;
  endtask

  task automatic gap;  // a control symbol between video periods
    step(3'd0, 8'h00, 4'h0, 2'b00);
  endtask

  initial begin
    integer len;
    // Control, guards, islands, and the out-of-range modes, on every input value.
    for (int c = 0; c < 4; c++) begin
      step(3'd0, 8'h5A, 4'h3, c[1:0]);
      step(3'd2, 8'hA5, 4'hC, c[1:0]);
      step(3'd4, 8'h0F, 4'h7, c[1:0]);
      for (int m = 5; m < 8; m++) step(m[2:0], 8'hFF, 4'h9, c[1:0]);
    end
    for (int n = 0; n < 16; n++) step(3'd3, 8'h00, n[3:0], n[1:0]);

    // Every byte in order, in one video period.
    gap();
    for (int v = 0; v < 256; v++) step(3'd1, v[7:0], 4'h0, 2'b00);
    // The disparity extremes: long runs of the most unbalanced bytes.
    gap();
    for (int i = 0; i < 64; i++) step(3'd1, 8'h00, 4'h0, 2'b00);
    gap();
    for (int i = 0; i < 64; i++) step(3'd1, 8'hFF, 4'h0, 2'b00);
    gap();
    for (int i = 0; i < 64; i++) step(3'd1, (i % 2) ? 8'h01 : 8'hFE, 4'h0, 2'b00);
    // Random runs of random bytes, each a new video period after a gap of a
    // random kind.
    for (int r = 0; r < 300; r++) begin
      step(3'($urandom_range(0, 4)) == 3'd1 ? 3'd0 : 3'($urandom_range(0, 4)), 8'($urandom),
           4'($urandom), 2'($urandom));
      len = $urandom_range(1, 80);
      for (int i = 0; i < len; i++) step(3'd1, 8'($urandom), 4'h0, 2'b00);
    end

    if (errors == 0 && n_video > 10000)
      $display(
          "tb_channel: PASS (%0d symbols on 3 lanes match the spec model; %0d video symbols decode, disparity %0d..%0d)",
          checked,
          n_video,
          min_disp,
          max_disp
      );
    else begin
      $display("tb_channel: FAIL %0d error(s), %0d video symbols", errors, n_video);
      $fatal(1);
    end
    $finish;
  end

endmodule

`default_nettype wire

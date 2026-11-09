// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//-----------------------------------------------------------------------------
// pll/pll_video_60k.v -- 1280x720p60 HDMI clocks on the GW5AT-60 (Tang Console 60K)
//
// Two PLLA stages and a CLKDIV make the exact CEA-861 VIC 4 clocks from the
// board's 50 MHz oscillator. The 138K twin (pll_video_138k.v) has the same
// module name and ports, so a board top instantiates either unchanged.
//
//   CLKIN   = 50 MHz.
//   CLKOUT  = 74.25 MHz pixel clock (CLKOUTD / 5 through the GW5A CLKDIV).
//   CLKOUTD = 371.25 MHz 5x pixel clock (DDR bit clock, OSER10 FCLK; see
//             rtl/hdmi_serializer.sv).
//
// Why two stages: 74.25/50 = 297/200, and one PLLA cannot express it. Gowin
// PA2078 requires PFD = FCLKIN/IDIV in 19..87.5 MHz (IDIV <= 2 from 50 MHz),
// which limits one hop to 73.333 MHz (-1.23%) or 75.0 MHz (+1.01%), both
// outside CEA's +/-0.5% VIC tolerance; strict scalers mis-frame a 75 MHz
// picture. Two integer stages reach the clock exactly:
//
//   stage 1: 50 MHz -> 27 MHz      IDIV=1 (PFD 50), FBDIV=1, MDIV=27
//                                  -> VCO = 50*27 = 1350 MHz; ODIV0=50 -> 27.0
//   stage 2: 27 MHz -> 371.25 MHz  IDIV=1 (PFD 27), FBDIV=1, MDIV=55
//                                  -> VCO = 27*55 = 1485 MHz; ODIV0=4 -> 371.25
//
// (GW5A PLLA model: PFD = FCLKIN/IDIV; VCO = FCLKIN*FBDIV*MDIV/IDIV;
// CLKOUTn = VCO/ODIVn. Gowin V1.9.12 accepts stage 2's 1485 MHz VCO. If a
// later tool rejects it (PA1019), the in-band alternative is 50 -> 137.5
// (IDIV=1, MDIV=22, VCO=1100, ODIV0=8) -> 371.25 (IDIV=5, PFD 27.5, MDIV=27,
// VCO=742.5, ODIV0=2).)
//
// The GW5A CLKDIV #(.DIV_MODE("5")) derives the pixel clock from CLKOUTD.
// CALIB=1 is mandatory so the divided clock's phase relative to FCLK is
// defined and OSER10 works. `lock` = both PLLAs locked. (GW5A CLKDIV has no
// GSREN parameter, unlike the GW2A one.)
//
// Under `PLL_SIM_FREE_RUN` the two clocks free-run for iverilog/Verilator,
// where the PLLA and CLKDIV primitives do not elaborate.
//-----------------------------------------------------------------------------

`default_nettype none

// verilog_lint: waive module-filename -- the 60K and 138K twins share one module name
module pll_video (
    input  wire clkin,
    output wire clkout,   // 74.25 MHz pixel clock (CLKDIV /5)
    output wire clkoutd,  // 371.25 MHz DDR bit clock (PLLA CLKOUT0)
    output wire lock
);

`ifdef PLL_SIM_FREE_RUN
  // Free-running clocks for iverilog/Verilator: pixel clock half-period
  // 6.7340 ns (74.25 MHz); DDR bit-clock half-period 1.3468 ns.
  reg clkout_r = 1'b0;
  reg clkoutd_r = 1'b0;
  initial begin
    #100;
    forever #6.7340 clkout_r = ~clkout_r;
  end
  initial begin
    #100;
    forever #1.3468 clkoutd_r = ~clkoutd_r;
  end
  assign clkout  = clkout_r;
  assign clkoutd = clkoutd_r;
  assign lock    = 1'b1;
  /* verilator lint_off UNUSED */
  wire _unused = clkin;
  /* verilator lint_on UNUSED */

`else
  // --- Stage 1: 50 MHz -> 27 MHz (PLLA, VCO 1350 MHz) --------------------
  wire clk27;
  wire lock27;

  PLLA #(
      .FCLKIN     ("50"),
      .IDIV_SEL   (1),           // PFD = 50 MHz (in 19..87.5)
      .FBDIV_SEL  (1),
      .ODIV0_SEL  (50),          // 1350 / 50 = 27.0 MHz
      .MDIV_SEL   (27),          // VCO = 50 * 27 = 1350 MHz
      .CLKOUT0_EN ("TRUE"),
      .CLKOUT1_EN ("FALSE"),
      .CLKFB_SEL  ("INTERNAL"),
      .DYN_DPA_EN ("FALSE"),
      .DYN_PE1_SEL("FALSE")
  ) u_pll27 (
      .CLKIN        (clkin),
      .CLKFB        (1'b0),
      .RESET        (1'b0),
      .PLLPWD       (1'b0),
      .RESET_I      (1'b0),
      .RESET_O      (1'b0),
      .PSSEL        (3'b000),
      .PSDIR        (1'b0),
      .PSPULSE      (1'b0),
      .SSCPOL       (1'b0),
      .SSCON        (1'b0),
      .SSCMDSEL     (7'b0),
      .SSCMDSEL_FRAC(3'b0),
      .MDCLK        (1'b0),
      .MDOPC        (2'b00),
      .MDAINC       (1'b0),
      .MDWDI        (8'b0),
      .MDRDO        (),
      .LOCK         (lock27),
      .CLKOUT0      (clk27),
      .CLKOUT1      (),
      .CLKOUT2      (),
      .CLKOUT3      (),
      .CLKOUT4      (),
      .CLKOUT5      (),
      .CLKOUT6      (),
      .CLKFBOUT     ()
  );

  // --- Stage 2: 27 MHz -> 371.25 MHz (PLLA, VCO 1485 MHz) ----------------
  wire vco_clkout;  // 371.25 MHz
  wire lock5x;
  wire div5_clkout;  // 74.25 MHz from CLKDIV /5

  PLLA #(
      .FCLKIN     ("27"),
      .IDIV_SEL   (1),           // PFD = 27 MHz (in 19..87.5)
      .FBDIV_SEL  (1),
      .ODIV0_SEL  (4),           // 1485 / 4 = 371.25 MHz
      .MDIV_SEL   (55),          // VCO = 27 * 55 = 1485 MHz
      .CLKOUT0_EN ("TRUE"),
      .CLKOUT1_EN ("FALSE"),
      .CLKFB_SEL  ("INTERNAL"),
      .DYN_DPA_EN ("FALSE"),
      .DYN_PE1_SEL("FALSE")
  ) u_pll5x (
      .CLKIN        (clk27),
      .CLKFB        (1'b0),
      .RESET        (1'b0),
      .PLLPWD       (1'b0),
      .RESET_I      (1'b0),
      .RESET_O      (1'b0),
      .PSSEL        (3'b000),
      .PSDIR        (1'b0),
      .PSPULSE      (1'b0),
      .SSCPOL       (1'b0),
      .SSCON        (1'b0),
      .SSCMDSEL     (7'b0),
      .SSCMDSEL_FRAC(3'b0),
      .MDCLK        (1'b0),
      .MDOPC        (2'b00),
      .MDAINC       (1'b0),
      .MDWDI        (8'b0),
      .MDRDO        (),
      .LOCK         (lock5x),
      .CLKOUT0      (vco_clkout),
      .CLKOUT1      (),
      .CLKOUT2      (),
      .CLKOUT3      (),
      .CLKOUT4      (),
      .CLKOUT5      (),
      .CLKOUT6      (),
      .CLKFBOUT     ()
  );

  // GW5A CLKDIV: divide the 371.25 MHz 5x clock by 5 to the 74.25 MHz pixel
  // clock. CALIB=1 is mandatory -- it pins the divided clock's phase relative
  // to HCLKIN so OSER10's PCLK/FCLK relationship is defined. (GW5A CLKDIV has
  // no GSREN param, unlike the GW2A one.)
  CLKDIV #(
      .DIV_MODE("5")
  ) u_div5 (
      .CLKOUT(div5_clkout),
      .CALIB (1'b1),
      .HCLKIN(vco_clkout),
      .RESETN(lock27 & lock5x)
  );

  assign clkout  = div5_clkout;
  assign clkoutd = vco_clkout;
  assign lock    = lock27 & lock5x;
`endif

endmodule

`default_nettype wire

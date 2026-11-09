// SPDX-License-Identifier: MIT OR Apache-2.0
// SPDX-FileCopyrightText: 2026 Howard M. Harte
`timescale 1ns / 1ps
//-----------------------------------------------------------------------------
// pll/pll_video_138k.v -- 1280x720p60 HDMI clocks on the GW5AST-138 (Tang Console 138K)
//
// The 138K twin of pll_video_60k.v, with the same module name and ports, so a
// board top instantiates either unchanged. The GW5AST-138 has no PLLA (gw_sh
// RP0008), so both stages use the GW5A generic `PLL`.
//
//   CLKIN   = 50 MHz.
//   CLKOUT  = 74.25 MHz pixel clock (CLKOUTD / 5 through the GW5A CLKDIV), the
//             exact CEA-861 VIC 4 clock.
//   CLKOUTD = 371.25 MHz 5x pixel clock (DDR bit clock, OSER10 FCLK).
//
// The stages match the 60K's (see that file for why two are needed):
//
//   stage 1: 50 MHz -> 27 MHz      IDIV=1 (PFD 50), MDIV=27
//                                  -> VCO = 50*27 = 1350 MHz; ODIV0=50 -> 27.0
//   stage 2: 27 MHz -> 371.25 MHz  IDIV=1 (PFD 27), MDIV=55
//                                  -> VCO = 27*55 = 1485 MHz; ODIV0=4 -> 371.25
//
// Frequency model: the generic GW5A `PLL` takes MDIV_SEL as the VCO multiplier
// (FBDIV_SEL is the feedback path, = 1), so VCO = FCLKIN x MDIV / IDIV, not
// x FBDIV as on the PLLA. An out-of-range VCO never locks and gives no error:
// the clock is dead and the design sits in reset (PLLA-style IDIV=2/FBDIV=2
// parameters give a 375 MHz VCO here). Keep the feedback divider an integer.
// CLKDIV #(.DIV_MODE("5")) derives the pixel clock; CALIB=1 pins its phase
// against FCLK for OSER10. `lock` = both PLLs locked.
//-----------------------------------------------------------------------------

`default_nettype none

// verilog_lint: waive module-filename -- the 60K and 138K twins share one module name
module pll_video (
    input  wire clkin,
    output wire clkout,   // 74.25 MHz pixel clock (CLKDIV /5)
    output wire clkoutd,  // 371.25 MHz DDR bit clock (PLL CLKOUT0)
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
  // --- Stage 1: 50 MHz -> 27 MHz (generic PLL, VCO 1350 MHz) --------------
  wire clk27;
  wire lock27;

  PLL #(
      .FCLKIN        ("50"),
      .DYN_IDIV_SEL  ("FALSE"),
      .IDIV_SEL      (1),           // /1  -> PFD = 50 MHz (in 19..87.5)
      .DYN_FBDIV_SEL ("FALSE"),
      .FBDIV_SEL     (1),
      .DYN_ODIV0_SEL ("FALSE"),
      .ODIV0_SEL     (50),          // 1350 / 50 = 27.0 MHz
      .ODIV0_FRAC_SEL(0),
      .DYN_MDIV_SEL  ("FALSE"),
      .MDIV_SEL      (27),          // VCO = 50 x 27 = 1350 MHz
      .CLKOUT0_EN    ("TRUE"),
      .CLKOUT1_EN    ("FALSE"),
      .CLKFB_SEL     ("INTERNAL"),
      .DYN_DPA_EN    ("FALSE")
  ) u_pll27 (
      .CLKIN        (clkin),
      .CLKFB        (1'b0),
      .RESET        (1'b0),
      .PLLPWD       (1'b0),
      .RESET_I      (1'b0),
      .RESET_O      (1'b0),
      .FBDSEL       (6'b0),
      .IDSEL        (6'b0),
      .MDSEL        (7'b0),
      .MDSEL_FRAC   (3'b0),
      .ODSEL0       (7'b0),
      .ODSEL0_FRAC  (3'b0),
      .ODSEL1       (7'b0),
      .ODSEL2       (7'b0),
      .ODSEL3       (7'b0),
      .ODSEL4       (7'b0),
      .ODSEL5       (7'b0),
      .ODSEL6       (7'b0),
      .DT0          (4'b0),
      .DT1          (4'b0),
      .DT2          (4'b0),
      .DT3          (4'b0),
      .ICPSEL       (6'b0),
      .LPFRES       (3'b0),
      .LPFCAP       (2'b0),
      .PSSEL        (3'b0),
      .PSDIR        (1'b0),
      .PSPULSE      (1'b0),
      .ENCLK0       (1'b1),
      .ENCLK1       (1'b0),
      .ENCLK2       (1'b0),
      .ENCLK3       (1'b0),
      .ENCLK4       (1'b0),
      .ENCLK5       (1'b0),
      .ENCLK6       (1'b0),
      .SSCPOL       (1'b0),
      .SSCON        (1'b0),
      .SSCMDSEL     (7'b0),
      .SSCMDSEL_FRAC(3'b0),
      .LOCK         (lock27),
      .CLKOUT0      (clk27),
      .CLKOUT1      (),
      .CLKOUT2      (),
      .CLKOUT3      (),
      .CLKOUT4      (),
      .CLKOUT5      (),
      .CLKOUT6      ()
  );

  // --- Stage 2: 27 MHz -> 371.25 MHz (generic PLL, VCO 1485 MHz) ----------
  wire vco_clkout;  // 371.25 MHz
  wire lock5x;
  wire div5_clkout;  // 74.25 MHz from CLKDIV /5

  PLL #(
      .FCLKIN        ("27"),
      .DYN_IDIV_SEL  ("FALSE"),
      .IDIV_SEL      (1),           // /1  -> PFD = 27 MHz (in 19..87.5)
      .DYN_FBDIV_SEL ("FALSE"),
      .FBDIV_SEL     (1),
      .DYN_ODIV0_SEL ("FALSE"),
      .ODIV0_SEL     (4),           // 1485 / 4 = 371.25 MHz
      .ODIV0_FRAC_SEL(0),
      .DYN_MDIV_SEL  ("FALSE"),
      .MDIV_SEL      (55),          // VCO = 27 x 55 = 1485 MHz
      .CLKOUT0_EN    ("TRUE"),
      .CLKOUT1_EN    ("FALSE"),
      .CLKFB_SEL     ("INTERNAL"),
      .DYN_DPA_EN    ("FALSE")
  ) u_pll5x (
      .CLKIN        (clk27),
      .CLKFB        (1'b0),
      .RESET        (1'b0),
      .PLLPWD       (1'b0),
      .RESET_I      (1'b0),
      .RESET_O      (1'b0),
      .FBDSEL       (6'b0),
      .IDSEL        (6'b0),
      .MDSEL        (7'b0),
      .MDSEL_FRAC   (3'b0),
      .ODSEL0       (7'b0),
      .ODSEL0_FRAC  (3'b0),
      .ODSEL1       (7'b0),
      .ODSEL2       (7'b0),
      .ODSEL3       (7'b0),
      .ODSEL4       (7'b0),
      .ODSEL5       (7'b0),
      .ODSEL6       (7'b0),
      .DT0          (4'b0),
      .DT1          (4'b0),
      .DT2          (4'b0),
      .DT3          (4'b0),
      .ICPSEL       (6'b0),
      .LPFRES       (3'b0),
      .LPFCAP       (2'b0),
      .PSSEL        (3'b0),
      .PSDIR        (1'b0),
      .PSPULSE      (1'b0),
      .ENCLK0       (1'b1),
      .ENCLK1       (1'b0),
      .ENCLK2       (1'b0),
      .ENCLK3       (1'b0),
      .ENCLK4       (1'b0),
      .ENCLK5       (1'b0),
      .ENCLK6       (1'b0),
      .SSCPOL       (1'b0),
      .SSCON        (1'b0),
      .SSCMDSEL     (7'b0),
      .SSCMDSEL_FRAC(3'b0),
      .LOCK         (lock5x),
      .CLKOUT0      (vco_clkout),
      .CLKOUT1      (),
      .CLKOUT2      (),
      .CLKOUT3      (),
      .CLKOUT4      (),
      .CLKOUT5      (),
      .CLKOUT6      ()
  );

  // GW5A CLKDIV: divide the 371.25 MHz 5x clock by 5 to the 74.25 MHz pixel
  // clock. CALIB=1 is mandatory -- it pins the divided clock's phase relative
  // to HCLKIN so OSER10's PCLK/FCLK relationship is defined.
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

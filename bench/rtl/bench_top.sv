// -----------------------------------------------------------------------------
// bench_top
//   Purpose      : The board-level top for the benchmark bitstream. Pads, PLL,
//                  reset, and the wiring between bench_core and ultra_sd_top.
//                  No measurement logic lives here -- that is bench_core, which
//                  is also what the simulation testbench instantiates, so the
//                  thing being validated in simulation is the thing that runs on
//                  the board.
//
//   THE PLL IS HERE, NOT IN THE CORE
//
//   R-CLK-5 forbids the core from instantiating a PLL, and means it: the core
//   takes SYS_CLK_HZ as a parameter and divides down, which is what makes it
//   portable to a system that happens to supply 100 MHz or 150 MHz. Section 2.5
//   says the harness converts the board's 27 MHz oscillator into the system
//   clock. This file is our stand-in for that harness, so the rPLL is ours and
//   the core never sees it.
//
//   WHY 99 MHz AND NOT 100
//
//     FCLKOUT = FCLKIN * (FBDIV_SEL+1) / (IDIV_SEL+1)
//     VCO     = FCLKOUT * ODIV_SEL,  which must land in 400..1200 MHz
//     PFD     = FCLKIN / (IDIV_SEL+1), which the rPLL wants at 3 MHz or more
//
//   100 MHz from 27 needs a ratio of 100/27, i.e. IDIV 27 and FBDIV 100, and
//   that puts the phase detector at 1 MHz -- below what the PLL will accept.
//   99 MHz is 27 * 33 / 9: PFD = 3 MHz, VCO = 99 * 8 = 792 MHz. Both legal, and
//   the arithmetic is exact rather than a rounded fraction.
//
//   99 / 2 = 49.5 MHz SD clock, which is inside the 50 MHz High Speed ceiling
//   with 1% to spare. R-DEG-3 treats that ceiling as hard, and 49.5 is the right
//   side of it; the 1% costs 2 Mbit/s of theoretical ceiling, which is cheaper
//   than arguing about whether 50.000 MHz is over the line.
//
//   CHECK THE DEFPARAMS BEFORE YOU TRUST THE CLOCK. The arithmetic above is
//   right; the exact set of rPLL defparams that Gowin's current EDA wants is the
//   kind of thing that changes between versions. If the build complains, or if
//   LOCK never rises, generate an rPLL for 27 -> 99 MHz with Gowin's Clock
//   Configuration IP and copy its defparam block over this one. Nothing else in
//   the design needs to change.
//
//   Clock domain : clk27 (pad) into the PLL; everything downstream runs on clk.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module bench_top #(
  // Measured payload per run, in 512-byte blocks. 131072 = 64 MB (R-PERF-4).
  // Override to something small (say 256) for the first bring-up run so a
  // mistake costs seconds instead of minutes.
  // 8192 blocks = 4 MB. THIS IS A DIAGNOSTIC SETTING, NOT A MEASUREMENT ONE:
  // R-PERF-4 wants one continuous 64 MB transfer and that is 131072, which is
  // what any reported throughput figure must come from. 4 MB is here because
  // the read-gap question is answered just as well by a short transfer, and at
  // 131072 one full sequence is ninety seconds -- long enough that a single
  // missed capture costs more than the measurement.
  parameter int TEST_BLOCKS = 131072,
  parameter int RUNS        = 5,
  parameter int DIV_TARGET  = 2,
  // Inter-command gap handed to the core, in SD clocks. 8 is the spec minimum
  // and the core's default; the bench asks for more because the first command
  // this board sends after a response -- CMD55, at the ACMD41 rung -- was the
  // one that went unanswered, and a gap measured in microseconds at the 399 kHz
  // identification clock costs nothing measurable.
  parameter int NCC_GAP_CLK = 64,

  // Which suite this bitstream runs: 0 = the graded measurement, 1 = the
  // sampling-phase margin matrix. See bench_core's SUITE parameter for why this
  // is a build-time choice and not a switch on the dock.
  //
  // bench_defines.sv is added FIRST by bench/build.tcl and GowinSynthesis
  // compiles the added files as one unit, so a `define there reaches this
  // default -- the same mechanism that turns ULTRA_SD_DEBUG_PORT on.
`ifdef BENCH_SUITE
  parameter int SUITE       = `BENCH_SUITE,
`else
  parameter int SUITE       = 0,
`endif

  // Payload per SUITE_EDGE case that is not a shape case.
  parameter int EDGE_BLOCKS = 4,

  // SUITE_CTRL / SUITE_SOAK sizing. SOAK_ITERS is what makes R-MEAS-5's
  // half-hour: at the tier divisor one pair of 8 blocks is about a millisecond,
  // so 64 is a smoke test and six figures is the soak.
  //
  // Overridable by macro for the same reason SUITE is: gw_sh has no -define,
  // so bench_defines.sv is the only place a build can say what it wants, and
  // the soak bitstream needs a different number from the smoke-test one
  // without either of them editing this file. bench/build_soak.tcl supplies
  // its own defines file.
  parameter int CTRL_BLOCKS = 8,
`ifdef BENCH_SOAK_ITERS
  parameter int SOAK_ITERS  = `BENCH_SOAK_ITERS,
`else
  parameter int SOAK_ITERS  = 64,
`endif
`ifdef BENCH_SOAK_BLOCKS
  parameter int SOAK_BLOCKS = `BENCH_SOAK_BLOCKS
`else
  parameter int SOAK_BLOCKS = 8
`endif
) (
  input  logic       clk27,      // 27 MHz board oscillator

  // ---- SD slot (constr/ultra_sd.cst) ---------------------------------------
  output logic       sd_clk,
  inout  wire        sd_cmd,
  inout  wire  [3:0] sd_dat,
  input  logic       sd_cd,

  // ---- report --------------------------------------------------------------
  output logic       uart_tx,
  output logic [3:0] led
);

  localparam int SYS_CLK_MHZ = 99;
  localparam int SYS_CLK_HZ  = SYS_CLK_MHZ * 1_000_000;

  // 99e6 / 115200 = 859.4; 859 is 0.05% fast, far inside a UART's tolerance.
  localparam int UART_CLKS_PER_BIT = 859;

  logic clk;
  logic pll_lock;

  // ===========================================================================
  // Clock
  // ===========================================================================
`ifdef ULTRA_SD_NO_VENDOR_PRIM
  // Simulation: no vendor primitive. The testbench drives clk27 at the system
  // clock rate directly and the PLL is a wire, so a simulation second is not
  // wasted modelling a frequency multiplier.
  assign clk      = clk27;
  assign pll_lock = 1'b1;
`else
  rPLL u_pll (
    .CLKOUT   (clk),
    .LOCK     (pll_lock),
    .CLKOUTP  (),
    .CLKOUTD  (),
    .CLKOUTD3 (),
    .RESET    (1'b0),
    .RESET_P  (1'b0),
    .CLKIN    (clk27),
    .CLKFB    (1'b0),
    .FBDSEL   (6'b0),
    .IDSEL    (6'b0),
    .ODSEL    (6'b0),
    .PSDA     (4'b0),
    .DUTYDA   (4'b0),
    .FDLY     (4'b0)
  );

  defparam u_pll.FCLKIN            = "27";
  defparam u_pll.DEVICE            = "GW2A-18C";
  defparam u_pll.DYN_IDIV_SEL      = "false";
  defparam u_pll.IDIV_SEL          = 8;      // /9  -> PFD = 3 MHz
  defparam u_pll.DYN_FBDIV_SEL     = "false";
  defparam u_pll.FBDIV_SEL         = 32;     // x33 -> 99 MHz
  defparam u_pll.DYN_ODIV_SEL      = "false";
  defparam u_pll.ODIV_SEL          = 8;      // VCO = 792 MHz
  defparam u_pll.PSDA_SEL          = "0000";
  defparam u_pll.DYN_DA_EN         = "false";
  defparam u_pll.DUTYDA_SEL        = "1000";
  defparam u_pll.CLKOUT_FT_DIR     = 1'b1;
  defparam u_pll.CLKOUTP_FT_DIR    = 1'b1;
  defparam u_pll.CLKOUT_DLY_STEP   = 0;
  defparam u_pll.CLKOUTP_DLY_STEP  = 0;
  defparam u_pll.CLKFB_SEL         = "internal";
  defparam u_pll.CLKOUT_BYPASS     = "false";
  defparam u_pll.CLKOUTP_BYPASS    = "false";
  defparam u_pll.CLKOUTD_BYPASS    = "false";
  defparam u_pll.DYN_SDIV_SEL      = 2;
  defparam u_pll.CLKOUTD_SRC       = "CLKOUT";
  defparam u_pll.CLKOUTD3_SRC      = "CLKOUT";
`endif

  // ===========================================================================
  // Reset: asynchronously asserted by configuration, synchronously released a
  // fixed time after the PLL locks (R-CLK-1).
  //
  // No reset pin. The dock has buttons, but their pin numbers are the one thing
  // in this pinout that is not independently verified (pin_check/README.md), and
  // a reset pin wired to the wrong pad holds the design in reset and looks
  // exactly like a dead bitstream. Power-cycling the board is the reset.
  //
  // 1024 cycles is ~10 us at 99 MHz: long enough for the clock tree to be
  // running everywhere, short enough to be invisible next to a 500 ms card init.
  // ===========================================================================
  logic [10:0] rst_cnt_q;
  logic        rst_n;

  always_ff @(posedge clk) begin
    if (!pll_lock)                     rst_cnt_q <= '0;
    else if (rst_cnt_q != 11'd1024)    rst_cnt_q <= rst_cnt_q + 11'd1;
  end

  assign rst_n = (rst_cnt_q == 11'd1024);

  // ===========================================================================
  // The core under measurement
  //
  // FIFO depth is two blocks per direction, which is what the streaming
  // structure needs and no more: a deeper FIFO would start to hide card time,
  // and Section 12.5 rules that out explicitly.
  // ===========================================================================
  logic [7:0]  awaddr, araddr;
  logic        awvalid, awready, wvalid, wready, bvalid, bready;
  logic        arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;

  // The core's init-ladder observation word, or zero when the core was built
  // without the port. bench_core takes it either way, so the measurement RTL
  // is the same module in both builds.
  logic [63:0] sd_dbg;
`ifndef ULTRA_SD_DEBUG_PORT
  assign sd_dbg = 64'h0;
`endif

  logic [31:0] rd_tdata, wr_tdata;
  logic        rd_tvalid, rd_tready, rd_tlast;
  logic        wr_tvalid, wr_tready, wr_tlast;
  logic        irq;

  ultra_sd_top #(
    .SYS_CLK_HZ     (SYS_CLK_HZ),
    .DATA_W         (32),
    .RD_FIFO_BLOCKS (4),
    .WR_FIFO_BLOCKS (2),
    .CRC_RETRIES    (3),
    .NCC_GAP_CLK    (NCC_GAP_CLK)
  ) u_sd (
    .clk              (clk),
    .rst_n            (rst_n),

    .s_axil_awaddr    (awaddr),
    .s_axil_awvalid   (awvalid),
    .s_axil_awready   (awready),
    .s_axil_wdata     (wdata),
    .s_axil_wstrb     (wstrb),
    .s_axil_wvalid    (wvalid),
    .s_axil_wready    (wready),
    .s_axil_bresp     (bresp),
    .s_axil_bvalid    (bvalid),
    .s_axil_bready    (bready),
    .s_axil_araddr    (araddr),
    .s_axil_arvalid   (arvalid),
    .s_axil_arready   (arready),
    .s_axil_rdata     (rdata),
    .s_axil_rresp     (rresp),
    .s_axil_rvalid    (rvalid),
    .s_axil_rready    (rready),

    .m_axis_rd_tdata  (rd_tdata),
    .m_axis_rd_tvalid (rd_tvalid),
    .m_axis_rd_tready (rd_tready),
    .m_axis_rd_tlast  (rd_tlast),

    .s_axis_wr_tdata  (wr_tdata),
    .s_axis_wr_tvalid (wr_tvalid),
    .s_axis_wr_tready (wr_tready),
    .s_axis_wr_tlast  (wr_tlast),

    .irq              (irq),

    .sd_clk           (sd_clk),
    .sd_cmd           (sd_cmd),
    .sd_dat           (sd_dat),
    .sd_cd            (sd_cd)
`ifdef ULTRA_SD_DEBUG_PORT
    , .dbg            (sd_dbg)
`endif
  );

  // ===========================================================================
  // The measurement
  // ===========================================================================
  logic bench_done, bench_pass;

  bench_core #(
    .SYS_CLK_MHZ       (SYS_CLK_MHZ),
    .DIV_TARGET        (DIV_TARGET),
    .TEST_BLOCKS       (TEST_BLOCKS),
    .RUNS              (RUNS),
    .SUITE             (SUITE),
    .EDGE_BLOCKS       (EDGE_BLOCKS),
    .CTRL_BLOCKS       (CTRL_BLOCKS),
    .SOAK_ITERS        (SOAK_ITERS),
    .SOAK_BLOCKS       (SOAK_BLOCKS),
    .UART_CLKS_PER_BIT (UART_CLKS_PER_BIT)
  ) u_bench (
    .clk         (clk),
    .rst_n       (rst_n),

    .m_awaddr    (awaddr),
    .m_awvalid   (awvalid),
    .m_awready   (awready),
    .m_wdata     (wdata),
    .m_wstrb     (wstrb),
    .m_wvalid    (wvalid),
    .m_wready    (wready),
    .m_bresp     (bresp),
    .m_bvalid    (bvalid),
    .m_bready    (bready),
    .m_araddr    (araddr),
    .m_arvalid   (arvalid),
    .m_arready   (arready),
    .m_rdata     (rdata),
    .m_rresp     (rresp),
    .m_rvalid    (rvalid),
    .m_rready    (rready),

    .rd_tdata_i  (rd_tdata),
    .rd_tvalid_i (rd_tvalid),
    .rd_tready_o (rd_tready),
    .rd_tlast_i  (rd_tlast),

    .wr_tdata_o  (wr_tdata),
    .wr_tvalid_o (wr_tvalid),
    .wr_tready_i (wr_tready),
    .wr_tlast_o  (wr_tlast),

    .sd_clk_i    (sd_clk),
    .dbg_i       (sd_dbg),

    .uart_tx_o   (uart_tx),
    .led_o       (led),
    .done_o      (bench_done),
    .pass_o      (bench_pass)
  );

endmodule

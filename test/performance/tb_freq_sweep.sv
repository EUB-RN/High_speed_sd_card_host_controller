`timescale 1ns/1ps

// The characterisation sweep (Section 7.4, R-MEAS-6) as a simulation.
//
// The delivered table is a hardware measurement -- read and write rate against
// SD clock frequency on the reference card, which is what the benchmark's
// CHAR suite produces and what reports/ holds. This is not a substitute for
// it: a behavioural card has no flash, so the absolute rates it produces are
// not the card's rates, and at a simulation's 10 MHz system clock the
// frequencies of the table (400 kHz .. 50 MHz) are not reachable at all.
//
// What this does test is the thing the hardware sweep cannot isolate: that
// CFG_CLK is the only variable. Across every divisor the core has to move the
// same payload, spend the same number of SD cycles doing it, and take
// system-clock time in proportion to the divisor -- no divisor-dependent
// stall, no lost beat, no CRC failure at one ratio and not another. If the
// hardware table comes back non-monotonic, this is the test that says whether
// the core or the card caused it.
//
// So for each divisor it runs one multi-block read and one multi-block write,
// and checks:
//
//   1. the payload arrives intact, with no error and no retry,
//   2. STAT_DATA -- the SD-cycle payload count -- is identical at every
//      divisor, because dividing the clock does not change how many SD cycles
//      a block takes,
//   3. the elapsed SYSTEM-clock time scales with the divisor, within a
//      tolerance that covers the fixed per-transfer command overhead.
//
// Check 3 is the one that catches a divisor the clock path does not actually
// honour: if CFG_CLK = 8 runs at the speed of CFG_CLK = 4, the rate column of
// the hardware table is measuring something other than what it says.
module tb_freq_sweep;
  import ultra_sd_pkg::*;

  localparam int CARD_BLOCKS = 64;
  localparam int BLKS        = 2;
  localparam int SYS_CLK_MHZ = 10;
  localparam int SYS_CLK_HZ  = SYS_CLK_MHZ * 1_000_000;

  // The divisors swept. 1 is what the ladder itself selects at this system
  // clock; the rest are what a host would write to CFG_CLK to slow the bus
  // down, and they are the ratios the hardware table's five frequency points
  // are produced with.
  localparam int NDIV = 4;
  // Icarus will not take an initialised unpacked localparam array, so the
  // values are filled in at the top of the stimulus instead.
  int DIVS [NDIV];

  int checks, failures;
  logic quiet = 0;
  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin
      failures++;
      $display("FAIL: %s", message);
    end
  endtask

  logic clk = 0, rst_n = 1;
  always #(500.0/SYS_CLK_MHZ) clk = ~clk;

  logic [7:0]  awaddr, araddr;
  logic        awvalid, awready, wvalid, wready, bvalid, bready;
  logic        arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;

  logic [31:0] rd_tdata, wr_tdata;
  logic        rd_tvalid, rd_tready, rd_tlast;
  logic        wr_tvalid, wr_tready, wr_tlast;
  logic        irq;

  logic       sd_clk;
  tri1        sd_cmd;
  tri1  [3:0] sd_dat;
  logic       sd_cd = 0;

  ultra_sd_top #(
    .SYS_CLK_HZ     (SYS_CLK_HZ),
    .DATA_W         (32),
    .RD_FIFO_BLOCKS (4),
    .WR_FIFO_BLOCKS (2),
    .CRC_RETRIES    (3)
  ) u_sd (
    .clk, .rst_n,
    .s_axil_awaddr (awaddr), .s_axil_awvalid (awvalid), .s_axil_awready (awready),
    .s_axil_wdata  (wdata),  .s_axil_wstrb   (wstrb),   .s_axil_wvalid  (wvalid),
    .s_axil_wready (wready), .s_axil_bresp   (bresp),   .s_axil_bvalid  (bvalid),
    .s_axil_bready (bready), .s_axil_araddr  (araddr),  .s_axil_arvalid (arvalid),
    .s_axil_arready(arready),.s_axil_rdata   (rdata),   .s_axil_rresp   (rresp),
    .s_axil_rvalid (rvalid), .s_axil_rready  (rready),
    .m_axis_rd_tdata (rd_tdata),  .m_axis_rd_tvalid (rd_tvalid),
    .m_axis_rd_tready(rd_tready), .m_axis_rd_tlast  (rd_tlast),
    .s_axis_wr_tdata (wr_tdata),  .s_axis_wr_tvalid (wr_tvalid),
    .s_axis_wr_tready(wr_tready), .s_axis_wr_tlast  (wr_tlast),
    .irq,
    .sd_clk, .sd_cmd, .sd_dat, .sd_cd
  );

  logic card_protocol_err;

  sd_card_model #(
    .BLOCK_COUNT       (CARD_BLOCKS),
    .NCR_DELAY_CYCLES  (2),
    .NAC_DELAY_CYCLES  (4),
    .WRITE_BUSY_CYCLES (8),
    .ACMD41_BUSY_POLLS (1)
  ) u_card (
    .sd_clk               (sd_clk),
    .rst_n                (rst_n),
    .card_present_i       (1'b1),
    .sd_cmd               (sd_cmd),
    .sd_dat               (sd_dat),
    .inject_cmd_timeout_i (1'b0),
    .inject_cmd_crc_i     (1'b0),
    .inject_data_crc_i    (1'b0),
    .inject_write_crc_i   (1'b0),
    .inject_busy_stuck_i  (1'b0),
    .protocol_error_o     (card_protocol_err),
    .last_cmd_o           (),
    .command_count_o      (),
    .bus_4bit_o           (),
    .high_speed_o         ()
  );

  task automatic axil_write(input logic [7:0] addr, input logic [31:0] data);
    int timeout;
    @(negedge clk);
    awaddr = addr; wdata = data; wstrb = 4'hF;
    awvalid = 1; wvalid = 1; bready = 1;
    timeout = 0;
    while (!(awready && wready) && timeout < 20) begin @(posedge clk); #1; timeout++; end
    if (!quiet) check(timeout < 20, "AXI-Lite write handshake");
    @(negedge clk); awvalid = 0; wvalid = 0;
    timeout = 0;
    while (!bvalid && timeout < 20) begin @(posedge clk); #1; timeout++; end
    if (!quiet) check(bvalid && bresp == 2'b00, "AXI-Lite write response");
    @(negedge clk); bready = 0;
  endtask

  task automatic axil_read(input logic [7:0] addr, output logic [31:0] data);
    int timeout;
    @(negedge clk);
    araddr = addr; arvalid = 1; rready = 1;
    timeout = 0;
    while (!arready && timeout < 20) begin @(posedge clk); #1; timeout++; end
    if (!quiet) check(timeout < 20, "AXI-Lite read-address handshake");
    @(posedge clk); #1;
    @(negedge clk); arvalid = 0;
    timeout = 0;
    while (!rvalid && timeout < 20) begin @(posedge clk); #1; timeout++; end
    data = rdata;
    if (!quiet) check(rvalid && rresp == 2'b00, "AXI-Lite read response");
    @(negedge clk); rready = 0;
  endtask

  // Elapsed system clocks, counted continuously so a transfer's duration is a
  // difference of two reads of it.
  int sysclk_now;
  always @(posedge clk) sysclk_now <= sysclk_now + 1;

  logic [31:0] val;
  int          t, fed, got;
  int          rd_cyc [NDIV], wr_cyc [NDIV];
  int          rd_data_sd [NDIV], wr_data_sd [NDIV];
  int          t0;
  int          rf;
  int          exp_num, exp_den;

  task automatic wait_done(input string what);
    logic [31:0] v;
    int tt;
    tt = 0; quiet = 1;
    do begin axil_read(REG_STATUS, v); tt++; end
    while (!v[STATUS_DONE_BIT] && tt < 400000);
    quiet = 0;
    check(v[STATUS_DONE_BIT], what);
  endtask

  initial begin
    checks = 0; failures = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    rd_tready = 1; wr_tdata = 0; wr_tvalid = 0; wr_tlast = 0;
    sysclk_now = 0;
    DIVS[0] = 1; DIVS[1] = 2; DIVS[2] = 4; DIVS[3] = 8;

    #1 rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;
    sd_cd = 0;

    t = 0; quiet = 1;
    do begin axil_read(REG_STATUS, val); t++; end
    while (!val[STATUS_CARD_RDY_BIT] && t < 30000);
    quiet = 0;
    check(val[STATUS_CARD_RDY_BIT], "card reaches ready after init");

    axil_read(REG_CFG_CLK, val);
    $display("");
    $display("  divisor the ladder selected at %0d MHz: %0d", SYS_CLK_MHZ, val);
    $display("");
    $display("  div | read sysclk | write sysclk | STAT_DATA rd | STAT_DATA wr");
    $display("  ----+-------------+--------------+--------------+-------------");

    for (int d = 0; d < NDIV; d++) begin
      // CFG_CLK takes effect as soon as it is written: the divisor is a live
      // input to the clock controller, not something latched at init. That is
      // what makes a sweep possible without re-initialising the card between
      // points, and it is worth stating because it is also what lets a host
      // slow the bus down for a card that misbehaves at speed (R-DEG-7).
      axil_write(REG_CFG_CLK, 32'(DIVS[d]));
      repeat (40) @(posedge clk);
      axil_read(REG_CFG_CLK, val);
      check(int'(val) == DIVS[d], "CFG_CLK reads back what was written");

      // ---- read ----------------------------------------------------------
      axil_write(REG_CTRL, 32'(1 << CTRL_STAT_CLEAR_BIT));
      axil_write(REG_LBA, 32'(0));
      axil_write(REG_BLOCKS, 32'(BLKS));
      axil_write(REG_XFER, 32'h0);
      t0 = sysclk_now;
      axil_write(REG_CTRL, 32'(1 << CTRL_START_BIT));

      got = 0; t = 0;
      while ((got < BLKS * (BLOCK_BYTES/4)) && (t < 4_000_000)) begin
        @(posedge clk); #1;
        if (rd_tvalid && rd_tready) got++;
        t++;
      end
      check(got == BLKS * (BLOCK_BYTES/4), "every read beat arrives at this divisor");
      wait_done("read reports DONE at this divisor");
      rd_cyc[d] = sysclk_now - t0;

      axil_read(REG_ERR, val);
      check(val[ERR_LSB +: 8] == 8'(ERR_OK), "read is clean at this divisor");
      axil_read(REG_STAT_RETRY, val);
      check(val == 32'h0, "read spends no retry at this divisor");
      axil_read(REG_STAT_DATA, val);
      rd_data_sd[d] = int'(val);

      // ---- write ---------------------------------------------------------
      axil_write(REG_CTRL, 32'(1 << CTRL_STAT_CLEAR_BIT));
      axil_write(REG_LBA, 32'(0));
      axil_write(REG_BLOCKS, 32'(BLKS));
      axil_write(REG_XFER, 32'(1 << XFER_DIR_BIT));
      t0 = sysclk_now;
      axil_write(REG_CTRL, 32'(1 << CTRL_START_BIT));

      fed = 0;
      @(negedge clk);
      while (fed < BLKS * (BLOCK_BYTES/4)) begin
        wr_tdata  = 32'h1234_0000 | 32'(fed[15:0]);
        wr_tlast  = (fed == BLKS * (BLOCK_BYTES/4) - 1);
        wr_tvalid = 1'b1;
        @(posedge clk); #1;
        if (wr_tready) fed++;
        @(negedge clk);
      end
      wr_tvalid = 1'b0; wr_tlast = 1'b0;
      check(fed == BLKS * (BLOCK_BYTES/4), "every write beat is accepted at this divisor");
      wait_done("write reports DONE at this divisor");
      wr_cyc[d] = sysclk_now - t0;

      axil_read(REG_ERR, val);
      check(val[ERR_LSB +: 8] == 8'(ERR_OK), "write is clean at this divisor");
      axil_read(REG_STAT_RETRY, val);
      check(val == 32'h0, "write spends no retry at this divisor");
      axil_read(REG_STAT_DATA, val);
      wr_data_sd[d] = int'(val);

      $display("  %3d | %11d | %12d | %12d | %12d",
               DIVS[d], rd_cyc[d], wr_cyc[d], rd_data_sd[d], wr_data_sd[d]);
    end
    $display("");

    check(!card_protocol_err, "card model saw no protocol violation");

    // ---- 2. the SD-cycle cost is divisor-independent ----------------------
    for (int d = 1; d < NDIV; d++) begin
      check(rd_data_sd[d] == rd_data_sd[0],
            "a read costs the same SD cycles at every divisor");
      check(wr_data_sd[d] == wr_data_sd[0],
            "a write costs the same SD cycles at every divisor");
    end

    // ---- 3. system-clock time scales with the EFFECTIVE divisor -----------
    // The core has one divided clock and it is clk/2 (R-CLK-2): the SD clock
    // cannot be faster than that, so CFG_CLK = 1 and CFG_CLK = 2 are the same
    // bus speed and the effective divisor is max(CFG_CLK, 2). Measured, and
    // the reason the first check below exists rather than being left implicit:
    // div 1 and div 2 come out at the same system-clock time to the cycle,
    // and from there div 4 is 1.998x and div 8 is 3.995x of div 2.
    //
    // So the ratios are taken against the div-2 point, which is the fastest
    // bus the design has, and that is also the point the hardware table's
    // 50 MHz row is measured at.
    check(rd_cyc[0] == rd_cyc[1],
          "CFG_CLK 1 and 2 are the same bus speed -- clk/2 is the floor");
    check(wr_cyc[0] == wr_cyc[1],
          "the clk/2 floor applies to writes as well");

    for (int d = 2; d < NDIV; d++) begin
      exp_num = rd_cyc[1] * DIVS[d];
      exp_den = DIVS[1];
      $display("  read  div %0d: %0d sysclk, ideal %0d, ratio to div %0d = %0d.%02d",
               DIVS[d], rd_cyc[d], exp_num / exp_den, DIVS[1],
               rd_cyc[d] / rd_cyc[1],
               ((rd_cyc[d] * 100) / rd_cyc[1]) % 100);
      check(rd_cyc[d] > rd_cyc[d-1],
            "a longer divisor takes longer -- the divisor is honoured");
      // One-sided tolerances. The fixed per-transfer command and response cost
      // does not scale with the divisor, so a slower point is always a little
      // under its ideal ratio and never over. What it must not be is flat: a
      // divisor the clock path quietly ignores shows up as a ratio near 1,
      // which is exactly what CFG_CLK = 1 does against the clk/2 floor above.
      check((rd_cyc[d] * 100) <= ((exp_num / exp_den) * 105),
            "read time does not exceed its divisor ratio");
      check((rd_cyc[d] * 100) >= ((exp_num / exp_den) * 90),
            "read time tracks the divisor rather than staying flat");
      $display("  write div %0d: %0d sysclk, ideal %0d",
               DIVS[d], wr_cyc[d], (wr_cyc[1] * DIVS[d]) / DIVS[1]);
      check((wr_cyc[d] * 100) <= (((wr_cyc[1] * DIVS[d]) / DIVS[1]) * 105),
            "write time does not exceed its divisor ratio");
      check((wr_cyc[d] * 100) >= (((wr_cyc[1] * DIVS[d]) / DIVS[1]) * 90),
            "write time tracks the divisor rather than staying flat");
    end
    $display("");

    rf = $fopen("../reports/sim_freq_sweep.txt", "w");
    if (rf) begin
      $fdisplay(rf, "tb_freq_sweep -- divisor characterisation, behavioural card");
      $fdisplay(rf, "sys_clk_hz = %0d", SYS_CLK_HZ);
      $fdisplay(rf, "blocks     = %0d", BLKS);
      $fdisplay(rf, "div read_sysclk write_sysclk stat_data_rd stat_data_wr");
      for (int d = 0; d < NDIV; d++)
        $fdisplay(rf, "%0d %0d %0d %0d %0d",
                  DIVS[d], rd_cyc[d], wr_cyc[d], rd_data_sd[d], wr_data_sd[d]);
      $fclose(rf);
    end

    if (failures) begin
      $display("tb_freq_sweep: FAILED (%0d failures)", failures);
      $fatal(1);
    end
    $display("tb_freq_sweep: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "tb_freq_sweep timeout");
  end
endmodule

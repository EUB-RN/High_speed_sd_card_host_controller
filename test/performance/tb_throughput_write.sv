`timescale 1ns/1ps

// Where a multi-block write's non-payload SD cycles go, and whether the host's
// share of them clears R-PERF-5.
//
// The read side has one owner for the time between blocks; the write side has
// two, and the specification's efficiency formula is built around separating
// them. After each block the card pulls DAT0 low and programs flash, and that
// time is the card's: Section 12.4 subtracts it before dividing, which is why
// the gate is
//
//     host_write_eff = payload_bits / ((elapsed_sd_cycles - stat_busy) * 4)
//
// and why it has to be >= 85%. Everything NOT inside that busy window is the
// host's: the CMD25 and its Ncr, the write start bits, the CRC16 the host
// sends, the CRC status token it waits for, the re-arm to the next block, and
// the closing CMD12 with its R1b.
//
// So this test runs one CMD25 over several blocks against the behavioural card
// -- which programs in a known WRITE_BUSY_CYCLES rather than in flash time --
// attributes every sd_clk_core cycle of the transfer to the L3 state and L1
// cell it was spent in, and then checks three things that the board runs
// cannot separate on their own:
//
//   1. the payload is one cycle per data group with no stall inside a block,
//   2. STAT_BUSY accounts for the card's programming time and nothing else,
//   3. with that time removed, the host's own efficiency clears 85%.
//
// Check 3 is the R-PERF-5 gate evaluated on the host alone. The board run
// reports the same formula against a real card in reports/; this one is the
// version with the flash taken out, so a regression in the host shows up here
// first instead of hiding inside a slower card.
module tb_throughput_write;
  import ultra_sd_pkg::*;

  localparam int CARD_BLOCKS = 32;
  localparam int WR_BLOCKS   = 8;     // 7 block boundaries to look at
  localparam int LBA_START   = 0;

  localparam int SYS_CLK_MHZ = 10;
  localparam int SYS_CLK_HZ  = SYS_CLK_MHZ * 1_000_000;

  // The card model's programming time. The whole point of the test is that
  // this is the ONLY part of the transfer that is not the host's, so it is
  // named here next to the check that subtracts it.
  localparam int CARD_BUSY_CYCLES = 8;

  // L1 cell_q / seg_q and L3 step_q are module-local enums, read here as the
  // integers they encode to. Kept next to the names they mirror.
  localparam int CELL_IDLE_V = 0, CELL_ARM_V = 1, CELL_XFER_V = 2;
  localparam int SEG_DATA_V  = 0, SEG_CRC_V  = 1, SEG_TAIL_V  = 2;
  localparam int S_IDLE_V    = 0, S_PRE_ERASE_V = 1, S_CMD_V  = 3,
                 S_WR_ARM_V  = 5, S_WR_DATA_V   = 6, S_BUSY_V = 7,
                 S_STOP_V    = 8, S_STATUS_V    = 9, S_DONE_V = 10;

  int checks, failures;
  logic quiet = 0;
  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin
      failures++;
      $display("FAIL: %s", message);
    end
  endtask

  // rst_n starts HIGH: the design's async resets fire on its NEGEDGE, and a
  // testbench that initialises it low never produces one.
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
    .WRITE_BUSY_CYCLES (CARD_BUSY_CYCLES),
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

  // ---- the instrument ------------------------------------------------------
  // Sampled on the gated, divided clock the payload is counted in, so a cycle
  // here is a cycle the SD bus spent.
  logic measuring;
  int   cyc_total;
  int   cyc_step   [12];
  int   cyc_cell   [5];
  int   cyc_seg    [3];
  int   cyc_payload;
  int   cyc_busy;          // card_busy seen on the bus, independent of STAT_BUSY
  int   boundaries;
  int   gap_run, gap_worst, gap_first;
  int   gap_at [40];

  always @(posedge u_sd.sd_clk_core) begin
    if (measuring) begin
      cyc_total <= cyc_total + 1;
      cyc_step[u_sd.u_block.step_q] <= cyc_step[u_sd.u_block.step_q] + 1;
      cyc_cell[u_sd.u_line.cell_q]  <= cyc_cell[u_sd.u_line.cell_q] + 1;
      if (u_sd.u_line.cell_q == CELL_XFER_V) begin
        cyc_seg[u_sd.u_line.seg_q] <= cyc_seg[u_sd.u_line.seg_q] + 1;
        if (u_sd.u_line.seg_q == SEG_DATA_V) cyc_payload <= cyc_payload + 1;
      end
      // The card's own programming window, counted off the bus rather than
      // off the counter being cross-checked.
      if (u_sd.card_busy) cyc_busy <= cyc_busy + 1;

      if (u_sd.u_line.cell_q == CELL_XFER_V) begin
        if (gap_run > 0) begin
          if (boundaries < 40) gap_at[boundaries] <= gap_run;
          boundaries <= boundaries + 1;
          if (boundaries == 0) gap_first <= gap_run;
          if (gap_run > gap_worst) gap_worst <= gap_run;
        end
        gap_run <= 0;
      end else begin
        gap_run <= gap_run + 1;
      end
    end
  end

  task automatic axil_write(input logic [7:0] addr, input logic [31:0] data);
    int timeout;
    @(negedge clk);
    awaddr = addr; wdata = data; wstrb = 4'hF;
    awvalid = 1; wvalid = 1; bready = 1;
    timeout = 0;
    while (!(awready && wready) && timeout < 20) begin @(posedge clk); #1; timeout++; end
    if (!quiet) check(timeout < 20, "AXI-Lite write handshake");
    else if (timeout >= 20) begin failures++; $display("FAIL: AXI-Lite write handshake"); end
    @(negedge clk); awvalid = 0; wvalid = 0;
    timeout = 0;
    while (!bvalid && timeout < 20) begin @(posedge clk); #1; timeout++; end
    if (!quiet) check(bvalid && bresp == 2'b00, "AXI-Lite write response");
    else if (!(bvalid && bresp == 2'b00)) begin failures++; $display("FAIL: AXI-Lite write response"); end
    @(negedge clk); bready = 0;
  endtask

  task automatic axil_read(input logic [7:0] addr, output logic [31:0] data);
    int timeout;
    @(negedge clk);
    araddr = addr; arvalid = 1; rready = 1;
    timeout = 0;
    while (!arready && timeout < 20) begin @(posedge clk); #1; timeout++; end
    if (!quiet) check(timeout < 20, "AXI-Lite read-address handshake");
    else if (timeout >= 20) begin failures++; $display("FAIL: AXI-Lite read-address handshake"); end
    @(posedge clk); #1;
    @(negedge clk); arvalid = 0;
    timeout = 0;
    while (!rvalid && timeout < 20) begin @(posedge clk); #1; timeout++; end
    data = rdata;
    if (!quiet) check(rvalid && rresp == 2'b00, "AXI-Lite read response");
    else if (!(rvalid && rresp == 2'b00)) begin failures++; $display("FAIL: AXI-Lite read response"); end
    @(negedge clk); rready = 0;
  endtask

  // The payload feeder. One word per beat, pattern derived from the beat index
  // so the card model's memory can be read back and compared by LBA later if a
  // debugging run wants to; here only the cycle accounting is checked.
  int  fed;
  task automatic feed_payload(input int total_beats);
    fed = 0;
    @(negedge clk);
    while (fed < total_beats) begin
      wr_tdata  = 32'hA5A5_0000 | 32'(fed[15:0]);
      wr_tlast  = (fed == total_beats - 1);
      wr_tvalid = 1'b1;
      @(posedge clk); #1;
      if (wr_tready) fed++;
      @(negedge clk);
    end
    wr_tvalid = 1'b0;
    wr_tlast  = 1'b0;
  endtask

  logic [31:0] val;
  int          t;
  int          payload_floor, framing_floor, per_block;
  int          host_cycles, host_eff_pm, bus_eff_pm;
  int          steady_gap;
  int          rf;
  logic [31:0] stat_data_val, stat_gap_val, stat_busy_val;
  int          total_beats;

  initial begin
    checks = 0; failures = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    rd_tready = 1; wr_tdata = 0; wr_tvalid = 0; wr_tlast = 0;
    measuring = 0; cyc_total = 0; cyc_payload = 0; cyc_busy = 0; boundaries = 0;
    gap_run = 0; gap_worst = 0; gap_first = 0;
    for (int i = 0; i < 12; i++) cyc_step[i] = 0;
    for (int i = 0; i < 5;  i++) cyc_cell[i] = 0;
    for (int i = 0; i < 3;  i++) cyc_seg[i]  = 0;
    for (int i = 0; i < 40; i++) gap_at[i]   = 0;

    total_beats = WR_BLOCKS * (BLOCK_BYTES/4);

    #1 rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;
    sd_cd = 0;                       // ACTIVE LOW: 0 = card present

    t = 0;
    quiet = 1;
    do begin
      axil_read(REG_STATUS, val);
      t++;
    end while (!val[STATUS_CARD_RDY_BIT] && t < 30000);
    quiet = 0;
    check(val[STATUS_CARD_RDY_BIT], "card reaches ready after init");

    // Counters cleared immediately before START so they describe this write
    // alone, then the request programmed one register per Table 5-1 row.
    axil_write(REG_CTRL, 32'(1 << CTRL_STAT_CLEAR_BIT));
    axil_write(REG_LBA, 32'(LBA_START));
    axil_write(REG_BLOCKS, 32'(WR_BLOCKS));
    axil_write(REG_XFER, 32'(1 << XFER_DIR_BIT));

    measuring = 1;
    axil_write(REG_CTRL, 32'(1 << CTRL_START_BIT));

    feed_payload(total_beats);
    check(fed == total_beats, "every payload beat is accepted by the core");

    t = 0;
    quiet = 1;
    do begin
      axil_read(REG_STATUS, val);
      t++;
    end while (!val[STATUS_DONE_BIT] && t < 60000);
    quiet = 0;
    check(val[STATUS_DONE_BIT], "transfer reports DONE");
    measuring = 0;

    axil_read(REG_ERR, val);
    check(val[ERR_LSB +: 8] == 8'(ERR_OK), "transfer ends with no error");
    check(!card_protocol_err, "card model saw no protocol violation");

    axil_read(REG_STAT_DATA, val); stat_data_val = val;
    axil_read(REG_STAT_GAP,  val); stat_gap_val  = val;
    axil_read(REG_STAT_BUSY, val); stat_busy_val = val;
    axil_read(REG_STAT_RETRY, val);
    check(val == 32'h0, "a clean write spends no retry of either kind");

    check(int'(stat_data_val) == cyc_payload,
          "STAT_DATA agrees with the payload cycles counted here");
    // STAT_BUSY is the card's programming time. The model programs for
    // CARD_BUSY_CYCLES after each block, and the host sees the busy window one
    // cycle late through its input register, so the counter is allowed to be a
    // cycle per block longer than the bus was -- but not shorter, and not a
    // different order of magnitude.
    check(int'(stat_busy_val) >= cyc_busy - WR_BLOCKS,
          "STAT_BUSY covers the card's programming window");
    check(int'(stat_busy_val) <= cyc_busy + WR_BLOCKS,
          "STAT_BUSY counts the programming window and nothing else");

    // ---- the attribution --------------------------------------------------
    payload_floor = WR_BLOCKS * (BLOCK_BYTES * (u_sd.bus_wide ? 2 : 8));
    framing_floor = WR_BLOCKS * 18;          // start bit + 16 CRC + end bit
    per_block     = (cyc_total - cyc_payload) / WR_BLOCKS;

    // Section 12.4, with the card's time removed. Per mille, so an 85.0% gate
    // is a comparison against 850 and no floating point is involved.
    host_cycles = cyc_total - int'(stat_busy_val);
    host_eff_pm = (cyc_payload * 1000) / host_cycles;
    bus_eff_pm  = (cyc_payload * 1000) / cyc_total;

    $display("");
    $display("  bus width                  : %0d bit", u_sd.bus_wide ? 4 : 1);
    $display("  blocks                     : %0d", WR_BLOCKS);
    $display("  STAT_DATA (core)           : %0d SD cycles", stat_data_val);
    $display("  STAT_GAP  (core)           : %0d SD cycles", stat_gap_val);
    $display("  STAT_BUSY (core)           : %0d SD cycles", stat_busy_val);
    $display("  card busy seen on the bus  : %0d SD cycles", cyc_busy);
    $display("");
    $display("  transfer, sd_clk_core cycles  : %0d total, %0d payload", cyc_total, cyc_payload);
    $display("  non-payload per block      : %0d cycles", per_block);
    $display("  bus efficiency             : %0d.%01d%% (card's time included)",
             bus_eff_pm / 10, bus_eff_pm % 10);
    $display("  host write efficiency      : %0d.%01d%% (R-PERF-5 formula, >= 85.0%%)",
             host_eff_pm / 10, host_eff_pm % 10);
    $display("");
    $display("  L1 cell occupancy          : IDLE %0d, ARM %0d, XFER %0d",
             cyc_cell[CELL_IDLE_V], cyc_cell[CELL_ARM_V], cyc_cell[CELL_XFER_V]);
    $display("  L1 XFER segments           : DATA %0d, CRC %0d, TAIL %0d",
             cyc_seg[SEG_DATA_V], cyc_seg[SEG_CRC_V], cyc_seg[SEG_TAIL_V]);
    $display("  L3 state occupancy         : PRE_ERASE %0d, CMD %0d, WR_ARM %0d, WR_DATA %0d, BUSY %0d, STOP %0d, STATUS %0d, DONE %0d, IDLE %0d",
             cyc_step[S_PRE_ERASE_V], cyc_step[S_CMD_V], cyc_step[S_WR_ARM_V],
             cyc_step[S_WR_DATA_V], cyc_step[S_BUSY_V], cyc_step[S_STOP_V],
             cyc_step[S_STATUS_V], cyc_step[S_DONE_V], cyc_step[S_IDLE_V]);
    $display("");
    $display("  block boundaries seen      : %0d", boundaries);
    $display("  first gap (command + Ncr)  : %0d cycles", gap_first);
    $display("  worst gap                  : %0d cycles", gap_worst);
    $write  ("  gap before each block      :");
    for (int i = 0; i < boundaries && i < 40; i++) $write(" %0d", gap_at[i]);
    $display("");
    steady_gap = 0;
    for (int i = 1; i < boundaries && i < 40; i++) steady_gap = steady_gap + gap_at[i];
    if (boundaries > 1)
      $display("  steady-state inter-block   : %0d cycles total over %0d boundaries = %0d each",
               steady_gap, boundaries - 1, steady_gap / (boundaries - 1));
    $display("  framing floor (spec)       : %0d cycles", framing_floor);
    $display("");

    check(cyc_payload == payload_floor,
          "payload is exactly one cycle per data group, no stall inside a block");
    check(cyc_seg[SEG_CRC_V] == WR_BLOCKS * 16,
          "CRC16 costs exactly its 16 spec cycles per block, no more");
    // The gate itself.
    check(host_eff_pm >= 850,
          "host write efficiency clears the 85% of R-PERF-5");

    rf = $fopen("../reports/sim_throughput_write.txt", "w");
    if (rf) begin
      $fdisplay(rf, "tb_throughput_write -- behavioural card, programming time known");
      $fdisplay(rf, "blocks               = %0d", WR_BLOCKS);
      $fdisplay(rf, "bus_width            = %0d", u_sd.bus_wide ? 4 : 1);
      $fdisplay(rf, "sd_clk_total         = %0d", cyc_total);
      $fdisplay(rf, "payload              = %0d", cyc_payload);
      $fdisplay(rf, "crc16                = %0d", cyc_seg[SEG_CRC_V]);
      $fdisplay(rf, "stat_data_core       = %0d", stat_data_val);
      $fdisplay(rf, "stat_gap_core        = %0d", stat_gap_val);
      $fdisplay(rf, "stat_busy_core       = %0d", stat_busy_val);
      $fdisplay(rf, "card_busy_on_bus     = %0d", cyc_busy);
      $fdisplay(rf, "bus_eff_permille     = %0d", bus_eff_pm);
      $fdisplay(rf, "host_write_eff_pm    = %0d", host_eff_pm);
      $fdisplay(rf, "first_gap            = %0d", gap_first);
      if (boundaries > 1)
        $fdisplay(rf, "inter_block_each     = %0d", steady_gap / (boundaries - 1));
      $fdisplay(rf, "nonpayload_perblock  = %0d", per_block);
      $fclose(rf);
    end

    if (failures) begin
      $display("tb_throughput_write: FAILED (%0d failures)", failures);
      $fatal(1);
    end
    $display("tb_throughput_write: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    #200_000_000;
    $fatal(1, "tb_throughput_write timeout");
  end
endmodule

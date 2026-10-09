`timescale 1ns/1ps

// Where a multi-block read's non-payload SD cycles go.
//
// The board runs report a read that is 92.4% payload: 80.6 SD cycles per block
// are spent not carrying data. That number alone does not say whose they are,
// and the two candidate owners lead to opposite conclusions -- if the card
// spaces its blocks, the host cannot do anything about it; if the host is slow
// to re-arm, it is ours to fix. This test settles it by running the identical
// path against the behavioural card, which has no flash, no FTL and a known
// inter-block delay (NAC_DELAY_CYCLES), and then attributing every line_clk
// cycle of the transfer to the L3 state and the L1 cell it was spent in.
//
// It is a measurement, so it prints a table; it is a test, so it also fails.
//
// WHAT IT FOUND. Per block, 4-bit, 16 blocks in one CMD18:
//
//   payload                 1024 cycles   one per data group, no stall inside
//   CRC16                     16 cycles   the specification's, not ours
//   boundary to next block      8 cycles   of which 7 are the model's own
//                                          D_RD_END + D_IDLE + NAC_DELAY +
//                                          D_RD_START
//   one-time, whole transfer   234 cycles  121 for CMD18 + Nac + arm,
//                                          113 for the closing CMD12
//
// So the host costs ONE SD cycle to re-arm between blocks. The board runs
// report 80.6 non-payload cycles per block; this path, with the host RTL
// unchanged and the card replaced by a model with no flash, costs 24. The
// ~57-cycle remainder is the real card spacing its own blocks, which no change
// here can shorten.
//
// That bounds the read path: 1024 payload + 18 framing cycles is a 98.3%
// ceiling for 4-bit SD, and the board's measured payload rate sits at 98.6% of
// it. There is no host-side read throughput left to recover; the next gain has
// to come from the signalling mode, not from this logic.
//
// The checks guard that conclusion rather than restate it: payload stays at one
// cycle per group, CRC16 stays at its 16 cycles, and the steady-state boundary
// stays within a cycle of the card's own gap. Any of those drifting costs
// throughput on the next board run, and breaks this test first.
module tb_throughput_read;
  import ultra_sd_pkg::*;

  localparam int CARD_BLOCKS = 32;
  localparam int RD_BLOCKS   = 16;    // 15 block boundaries to look at
  localparam int LBA_START   = 0;

  localparam int SYS_CLK_MHZ = 10;
  localparam int SYS_CLK_HZ  = SYS_CLK_MHZ * 1_000_000;

  // L1 cell_q / seg_q and L3 step_q are module-local enums, so they are read
  // here as the integers they encode to. Kept next to the names they mirror.
  localparam int CELL_IDLE_V = 0, CELL_ARM_V = 1, CELL_XFER_V = 2;
  localparam int SEG_DATA_V  = 0, SEG_CRC_V  = 1, SEG_TAIL_V  = 2;
  localparam int S_IDLE_V    = 0, S_RD_ARM_V = 2, S_CMD_V     = 3,
                 S_RD_DATA_V = 4, S_STOP_V   = 8, S_STATUS_V  = 9,
                 S_DONE_V    = 10;

  int checks, failures;
  // Polling loops run the same handshake check thousands of times; counted once
  // is informative, counted 20000 times is noise.
  logic quiet = 0;
  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin
      failures++;
      $display("FAIL: %s", message);
    end
  endtask

  // rst_n starts HIGH: the design's async resets fire on its NEGEDGE, and a
  // testbench that initialises it low never produces one, so everything clocked
  // by the parked sd_clk -- the card model among it -- stays at X forever.
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

  // ---- the instrument ------------------------------------------------------
  // Sampled on the gated, divided LINE clock, which is the clock the payload
  // is actually counted in, so a cycle here is a cycle the SD bus spent.
  logic measuring;
  int   cyc_total;
  int   cyc_step   [12];   // L3 step_q occupancy
  int   cyc_cell   [5];    // L1 cell_q occupancy
  int   cyc_seg    [3];    // L1 seg_q occupancy while CELL_XFER
  int   cyc_payload;       // CELL_XFER && SEG_DATA: the only cycles that carry data
  int   boundaries;        // block ends seen
  int   gap_run, gap_worst, gap_first;
  int   gap_at [40];

  always @(posedge u_sd.line_clk) begin
    if (measuring) begin
      cyc_total <= cyc_total + 1;
      cyc_step[u_sd.u_block.step_q] <= cyc_step[u_sd.u_block.step_q] + 1;
      cyc_cell[u_sd.u_line.cell_q]  <= cyc_cell[u_sd.u_line.cell_q] + 1;
      if (u_sd.u_line.cell_q == CELL_XFER_V) begin
        cyc_seg[u_sd.u_line.seg_q] <= cyc_seg[u_sd.u_line.seg_q] + 1;
        if (u_sd.u_line.seg_q == SEG_DATA_V) cyc_payload <= cyc_payload + 1;
      end

      // A "gap" here is any stretch with the cell not transferring: the span
      // between one block's last CRC cycle and the next block's start bit.
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

  logic [31:0] val;
  int          beats, t;
  int          payload_floor, framing_floor, per_block, cost_above_floor;
  int          steady_gap;
  int          rf;
  logic [31:0] stat_gap_val;

  initial begin
    checks = 0; failures = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    rd_tready = 1; wr_tdata = 0; wr_tvalid = 0; wr_tlast = 0;
    measuring = 0; cyc_total = 0; cyc_payload = 0; boundaries = 0;
    gap_run = 0; gap_worst = 0; gap_first = 0;
    for (int i = 0; i < 12; i++) cyc_step[i] = 0;
    for (int i = 0; i < 5;  i++) cyc_cell[i] = 0;
    for (int i = 0; i < 3;  i++) cyc_seg[i]  = 0;
    for (int i = 0; i < 40; i++) gap_at[i]  = 0;

    #1 rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;
    sd_cd = 0;                       // ACTIVE LOW: 0 = card present

    // Init runs on its own; wait for STATUS.CARD_READY the way a driver would.
    t = 0;
    quiet = 1;
    do begin
      axil_read(REG_STATUS, val);
      t++;
    end while (!val[STATUS_CARD_RDY_BIT] && t < 30000);
    quiet = 0;
    check(val[STATUS_CARD_RDY_BIT], "card reaches ready after init");

    axil_read(REG_CARD_BLK, val);
    check(val != 32'h0, "CARD_BLK is decoded from the CSD");

    // The transfer. Counters cleared immediately before START so STAT_DATA and
    // STAT_GAP describe this read alone.
    axil_write(REG_CTRL, 32'(1 << CTRL_STAT_CLEAR_BIT));
    axil_write(REG_LBA, 32'(LBA_START));
    axil_write(REG_XFER_CFG, {1'b0, 7'h00, 24'(RD_BLOCKS)});

    measuring = 1;
    axil_write(REG_CTRL, 32'(1 << CTRL_START_BIT));

    beats = 0;
    t     = 0;
    while ((beats < RD_BLOCKS * (BLOCK_BYTES/4)) && (t < 2_000_000)) begin
      @(posedge clk); #1;
      if (rd_tvalid && rd_tready) beats++;
      t++;
    end
    check(beats == RD_BLOCKS * (BLOCK_BYTES/4), "every payload beat reaches the host");

    t = 0;
    quiet = 1;
    do begin
      axil_read(REG_STATUS, val);
      t++;
    end while (!val[STATUS_DONE_BIT] && t < 30000);
    quiet = 0;
    check(val[STATUS_DONE_BIT], "transfer reports DONE");
    measuring = 0;

    axil_read(REG_ERR, val);
    check(val[ERR_LSB +: 8] == 8'(ERR_OK), "transfer ends with no error");
    check(!card_protocol_err, "card model saw no protocol violation");

    // ---- what the core itself counted, for cross-check --------------------
    axil_read(REG_STAT_DATA, val);
    check(int'(val) == cyc_payload,
          "STAT_DATA agrees with the payload cycles counted here");
    $display("");
    $display("  bus width                  : %0d bit", u_sd.bus_wide ? 4 : 1);
    $display("  blocks                     : %0d", RD_BLOCKS);
    $display("  STAT_DATA (core)           : %0d SD cycles", val);
    axil_read(REG_STAT_GAP, val);
    stat_gap_val = val;
    $display("  STAT_GAP  (core)           : %0d SD cycles", val);

    // ---- the attribution --------------------------------------------------
    payload_floor = RD_BLOCKS * (BLOCK_BYTES * (u_sd.bus_wide ? 2 : 8));
    framing_floor = RD_BLOCKS * 18;          // start bit + 16 CRC + end bit
    per_block     = (cyc_total - cyc_payload) / RD_BLOCKS;

    $display("");
    $display("  transfer, line_clk cycles  : %0d total, %0d payload (%0d.%01d%%)",
             cyc_total, cyc_payload,
             (cyc_payload * 100) / cyc_total,
             (((cyc_payload * 1000) / cyc_total) % 10));
    $display("  non-payload per block      : %0d cycles", per_block);
    $display("");
    $display("  L1 cell occupancy          : IDLE %0d, ARM %0d, XFER %0d",
             cyc_cell[CELL_IDLE_V], cyc_cell[CELL_ARM_V], cyc_cell[CELL_XFER_V]);
    $display("  L1 XFER segments           : DATA %0d, CRC %0d, TAIL %0d",
             cyc_seg[SEG_DATA_V], cyc_seg[SEG_CRC_V], cyc_seg[SEG_TAIL_V]);
    $display("  L3 state occupancy         : RD_ARM %0d, CMD %0d, RD_DATA %0d, STOP %0d, STATUS %0d, DONE %0d, IDLE %0d",
             cyc_step[S_RD_ARM_V], cyc_step[S_CMD_V], cyc_step[S_RD_DATA_V],
             cyc_step[S_STOP_V], cyc_step[S_STATUS_V], cyc_step[S_DONE_V],
             cyc_step[S_IDLE_V]);
    $display("");
    $display("  block boundaries seen      : %0d", boundaries);
    $display("  first gap (command + Nac)  : %0d cycles", gap_first);
    $display("  worst gap                  : %0d cycles", gap_worst);
    $write  ("  gap before each block      :");
    for (int i = 0; i < boundaries && i < 40; i++) $write(" %0d", gap_at[i]);
    $display("");
    steady_gap = 0;
    for (int i = 1; i < boundaries && i < 40; i++) steady_gap = steady_gap + gap_at[i];
    if (boundaries > 1)
      $display("  steady-state inter-block   : %0d cycles total over %0d boundaries = %0d each",
               steady_gap, boundaries - 1, steady_gap / (boundaries - 1));
    $display("");

    check(cyc_payload == payload_floor,
          "payload is exactly one cycle per data group, no stall inside a block");
    cost_above_floor = (cyc_total - cyc_payload) - framing_floor;
    $display("  framing floor (spec)       : %0d cycles", framing_floor);
    $display("  cost above the floor       : %0d cycles (%0d per block)",
             cost_above_floor, cost_above_floor / RD_BLOCKS);
    $display("");

    // The invariant worth guarding is the steady-state boundary, because it is
    // the only per-block cost the host controls. The card model's driver spends
    // NAC_DELAY_CYCLES in D_RD_DELAY plus one cycle each in D_RD_END, D_IDLE
    // and D_RD_START, so 7 of those cycles are the model's by construction and
    // the host's share is whatever is left. Measured: 8, so the host costs one
    // cycle to re-arm between blocks. 10 fails on any real regression there
    // while tolerating a one-cycle pipeline change.
    check((steady_gap / (boundaries - 1)) <= 10,
          "host re-arms between blocks within a cycle of the card's own gap");
    check(cyc_seg[SEG_CRC_V] == RD_BLOCKS * 16,
          "CRC16 costs exactly its 16 spec cycles per block, no more");

    // The category's rule is that measured numbers land in reports/, not only in
    // a log that scrolls away. Best effort: a run from somewhere the relative
    // path does not resolve still passes, it just does not leave the artefact.
    rf = $fopen("../reports/sim_throughput_read.txt", "w");
    if (rf) begin
      $fdisplay(rf, "tb_throughput_read -- behavioural card, no flash");
      $fdisplay(rf, "blocks              = %0d", RD_BLOCKS);
      $fdisplay(rf, "bus_width           = %0d", u_sd.bus_wide ? 4 : 1);
      $fdisplay(rf, "line_clk_total      = %0d", cyc_total);
      $fdisplay(rf, "payload             = %0d", cyc_payload);
      $fdisplay(rf, "crc16               = %0d", cyc_seg[SEG_CRC_V]);
      $fdisplay(rf, "stat_gap_core       = %0d", stat_gap_val);
      $fdisplay(rf, "first_gap           = %0d", gap_first);
      $fdisplay(rf, "inter_block_each    = %0d", steady_gap / (boundaries - 1));
      $fdisplay(rf, "nonpayload_perblock = %0d", per_block);
      $fclose(rf);
    end

    if (failures) begin
      $display("tb_throughput_read: FAILED (%0d failures)", failures);
      $fatal(1);
    end
    $display("tb_throughput_read: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    #200_000_000;
    $fatal(1, "tb_throughput_read timeout");
  end
endmodule

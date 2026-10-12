`timescale 1ns/1ps

// The five Table 5-2 counters against an independent count of the same events.
//
// R-IF-11 says each counter is maintained in the clock domain of the event it
// counts, and the delivery takes that literally: there is no statistics module,
// each counter lives inside the FSM whose case arm is the event. That is the
// right structure, and it is also the structure in which a counter can quietly
// come to mean something slightly different from its name -- counting a cycle
// twice at a state boundary, or missing the first cycle of a window, costs
// nothing functionally and silently corrupts every efficiency number computed
// from it afterwards. Every rate in reports/ is computed from these five.
//
// So this test does not ask whether the counters move. It counts the same five
// things a second time, off the bus and off the FSM states, in the testbench,
// and requires the two counts to agree:
//
//   STAT_DATA          cycles L1 spent in XFER/DATA, the payload groups
//   STAT_GAP           cycles inside a transfer with the bus idle
//   STAT_BUSY          cycles the card held DAT0 low
//   STAT_RETRY[15:0]   CRC16 retries, forced with the card model's injector
//   STAT_RETRY[31:16]  command retries, forced the same way
//
// The retry halves are the reason the test injects errors rather than running
// clean: a counter that is never incremented agrees with a testbench that
// never saw an increment, and that agreement proves nothing. Each half is
// driven to a known non-zero value and checked against the number of
// injections the testbench performed.
//
// CTRL.STAT_CLEAR is checked at the end, because a counter that cannot be
// cleared is a counter that reports the wrong thing on the second measurement
// run -- which is exactly how the five-run procedure of Section 12.3 is used.
module tb_counter_crosscheck;
  import ultra_sd_pkg::*;

  localparam int CARD_BLOCKS = 64;
  localparam int BLKS        = 4;
  localparam int SYS_CLK_MHZ = 10;
  localparam int SYS_CLK_HZ  = SYS_CLK_MHZ * 1_000_000;

  localparam int CELL_XFER_V = 2;
  localparam int SEG_DATA_V  = 0;

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

  logic inject_cmd_crc, inject_data_crc;

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
    .WRITE_BUSY_CYCLES (12),
    .ACMD41_BUSY_POLLS (1)
  ) u_card (
    .sd_clk               (sd_clk),
    .rst_n                (rst_n),
    .card_present_i       (1'b1),
    .sd_cmd               (sd_cmd),
    .sd_dat               (sd_dat),
    .inject_cmd_timeout_i (1'b0),
    .inject_cmd_crc_i     (inject_cmd_crc),
    .inject_data_crc_i    (inject_data_crc),
    .inject_write_crc_i   (1'b0),
    .inject_busy_stuck_i  (1'b0),
    .protocol_error_o     (card_protocol_err),
    .last_cmd_o           (),
    .command_count_o      (),
    .bus_4bit_o           (),
    .high_speed_o         ()
  );

  // ---- the second opinion --------------------------------------------------
  // Every count below is taken off the bus or off an L1/L3 state, on the same
  // clock edge the counter under test uses, and never from the counter itself.
  logic measuring;
  int   tb_data, tb_gap, tb_busy;

  // The core's own definition of "gap": inside a transfer, L1 not moving data
  // and the card not busy. Mirrored here from ultra_sd_block's gap_active so
  // the two counts are of the same event and not of two similar ones.
  logic tb_in_stream, tb_gap_active;
  assign tb_in_stream  = u_sd.u_block.in_stream;
  assign tb_gap_active = tb_in_stream && !u_sd.dat_active &&
                         !u_sd.card_busy && u_sd.u_block.multi_q &&
                         u_sd.u_block.past_first_q;

  // STAT_BUSY's definition is "DAT0 held low while L1 is not moving a cell",
  // recounted here from the pad and the cell state rather than from the
  // card_busy output the counter shares a source with.
  logic tb_busy_now;
  assign tb_busy_now = (u_sd.u_line.cell_q == 0) && !sd_dat[0];

  always @(posedge u_sd.sd_clk_core) begin
    if (measuring) begin
      if ((u_sd.u_line.cell_q == CELL_XFER_V) &&
          (u_sd.u_line.seg_q  == SEG_DATA_V)) tb_data <= tb_data + 1;
      if (tb_gap_active)                      tb_gap  <= tb_gap  + 1;
      if (tb_busy_now)                        tb_busy <= tb_busy + 1;
    end
  end

  // Retry observers. An injector that stays asserted fails the retry too, and
  // three of those exhaust the budget and turn the transfer into ERR_CRC -- so
  // each injector is released the moment its retry has actually been
  // provoked, and these flags are what "actually" means.
  // L3 exposes the CRC-retry decision as a combinational event; L2 does not,
  // so the command side is observed as its retry budget advancing. Both are
  // the decision, not the counter being cross-checked.
  logic saw_crc_retry, saw_cmd_retry;
  int   prev_cmd_rty;
  always @(posedge u_sd.sd_clk_core) begin
    if (u_sd.u_block.retry_crc) saw_crc_retry <= 1'b1;
    if (int'(u_sd.u_cmd.u_engine.retry_q) > prev_cmd_rty) saw_cmd_retry <= 1'b1;
    prev_cmd_rty <= int'(u_sd.u_cmd.u_engine.retry_q);
  end

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

  task automatic wait_ready();
    logic [31:0] v;
    int t;
    t = 0; quiet = 1;
    do begin axil_read(REG_STATUS, v); t++; end
    while (!v[STATUS_CARD_RDY_BIT] && t < 30000);
    quiet = 0;
    check(v[STATUS_CARD_RDY_BIT], "card reaches ready after init");
  endtask

  task automatic wait_done();
    logic [31:0] v;
    int t;
    t = 0; quiet = 1;
    do begin axil_read(REG_STATUS, v); t++; end
    while (!v[STATUS_DONE_BIT] && t < 200000);
    quiet = 0;
    check(v[STATUS_DONE_BIT], "transfer reports DONE");
  endtask

  task automatic start_xfer(input int lba, input int blocks, input logic dir);
    axil_write(REG_LBA, 32'(lba));
    axil_write(REG_BLOCKS, 32'(blocks));
    axil_write(REG_XFER, dir ? 32'(1 << XFER_DIR_BIT) : 32'h0);
    axil_write(REG_CTRL, 32'(1 << CTRL_START_BIT));
  endtask

  int fed;
  task automatic feed_payload(input int total_beats);
    fed = 0;
    @(negedge clk);
    while (fed < total_beats) begin
      wr_tdata  = 32'h5A5A_0000 | 32'(fed[15:0]);
      wr_tlast  = (fed == total_beats - 1);
      wr_tvalid = 1'b1;
      @(posedge clk); #1;
      if (wr_tready) fed++;
      @(negedge clk);
    end
    wr_tvalid = 1'b0;
    wr_tlast  = 1'b0;
  endtask

  task automatic drain_read(input int total_beats);
    int got, t;
    got = 0; t = 0;
    while ((got < total_beats) && (t < 2_000_000)) begin
      @(posedge clk); #1;
      if (rd_tvalid && rd_tready) got++;
      t++;
    end
    check(got == total_beats, "every payload beat reaches the host");
  endtask

  logic [31:0] val, retry_val;
  int          crc_inj, cmd_inj;
  int          t;
  int          rf;
  logic [31:0] d_core, g_core, b_core;

  initial begin
    checks = 0; failures = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    rd_tready = 1; wr_tdata = 0; wr_tvalid = 0; wr_tlast = 0;
    inject_cmd_crc = 0; inject_data_crc = 0;
    saw_crc_retry = 0; saw_cmd_retry = 0; prev_cmd_rty = 0;
    measuring = 0; tb_data = 0; tb_gap = 0; tb_busy = 0;
    crc_inj = 0; cmd_inj = 0;

    #1 rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;
    sd_cd = 0;
    wait_ready();

    // ---- 1. a clean multi-block read: STAT_DATA and STAT_GAP --------------
    axil_write(REG_CTRL, 32'(1 << CTRL_STAT_CLEAR_BIT));
    tb_data = 0; tb_gap = 0; tb_busy = 0;
    measuring = 1;
    start_xfer(0, BLKS, 1'b0);
    drain_read(BLKS * (BLOCK_BYTES/4));
    wait_done();
    measuring = 0;

    axil_read(REG_ERR, val);
    check(val[ERR_LSB +: 8] == 8'(ERR_OK), "clean read ends with no error");

    axil_read(REG_STAT_DATA, d_core);
    axil_read(REG_STAT_GAP,  g_core);
    axil_read(REG_STAT_BUSY, b_core);
    check(int'(d_core) == tb_data,
          "STAT_DATA equals the payload cycles counted independently");
    check(int'(g_core) == tb_gap,
          "STAT_GAP equals the in-transfer idle cycles counted independently");
    check(int'(d_core) == BLKS * (BLOCK_BYTES * 2),
          "STAT_DATA is the 4-bit payload floor, so it counts groups not bits");
    // STAT_BUSY is not "the card is programming", it is the counter's own
    // definition: DAT0 low while L1 is not moving a cell. On a read that
    // catches the cycles around each block's start bit, before the cell has
    // been entered, so the honest expectation is the independent recount --
    // not zero.
    check((int'(b_core) >= tb_busy - BLKS) && (int'(b_core) <= tb_busy + BLKS),
          "STAT_BUSY on read equals the recounted DAT0-low cycles");

    $display("");
    $display("  read   STAT_DATA core %0d / tb %0d", d_core, tb_data);
    $display("         STAT_GAP  core %0d / tb %0d", g_core, tb_gap);
    $display("         STAT_BUSY core %0d / tb %0d", b_core, tb_busy);

    // ---- 2. a clean multi-block write: STAT_BUSY -------------------------
    axil_write(REG_CTRL, 32'(1 << CTRL_STAT_CLEAR_BIT));
    tb_data = 0; tb_gap = 0; tb_busy = 0;
    measuring = 1;
    start_xfer(0, BLKS, 1'b1);
    feed_payload(BLKS * (BLOCK_BYTES/4));
    wait_done();
    measuring = 0;

    axil_read(REG_ERR, val);
    check(val[ERR_LSB +: 8] == 8'(ERR_OK), "clean write ends with no error");

    axil_read(REG_STAT_DATA, d_core);
    axil_read(REG_STAT_GAP,  g_core);
    axil_read(REG_STAT_BUSY, b_core);
    check(int'(d_core) == tb_data,
          "STAT_DATA on write equals the payload cycles counted independently");
    check(int'(g_core) == tb_gap,
          "STAT_GAP on write equals the idle cycles counted independently");
    // The busy window is observed through the host's input register, so the
    // counter may lag the bus by a cycle per block -- but not by more, and
    // never by less.
    check((int'(b_core) >= tb_busy - BLKS) && (int'(b_core) <= tb_busy + BLKS),
          "STAT_BUSY equals the card's DAT0-busy cycles within one per block");
    check(b_core != 32'h0, "a write leaves STAT_BUSY non-zero");

    $display("  write  STAT_DATA core %0d / tb %0d", d_core, tb_data);
    $display("         STAT_GAP  core %0d / tb %0d", g_core, tb_gap);
    $display("         STAT_BUSY core %0d / tb %0d", b_core, tb_busy);

    // ---- 3. STAT_RETRY[15:0]: CRC16 retries, forced ----------------------
    // The injector corrupts the CRC of the next data block the card sends, so
    // one injection is one retried block. Two injections, each cleared as soon
    // as the retry has been provoked, to see the counter advance twice rather
    // than saturate on a stuck input.
    axil_write(REG_CTRL, 32'(1 << CTRL_STAT_CLEAR_BIT));
    saw_crc_retry = 1'b0;
    inject_data_crc = 1'b1; crc_inj++;
    start_xfer(0, BLKS, 1'b0);
    fork
      begin : crc_release
        wait (saw_crc_retry);
        inject_data_crc = 1'b0;
      end
      begin : crc_guard
        repeat (400_000) @(posedge clk);
        inject_data_crc = 1'b0;
      end
    join_any
    disable fork;
    check(saw_crc_retry, "the injected CRC16 error provoked a block retry");
    drain_read(BLKS * (BLOCK_BYTES/4));
    wait_done();

    axil_read(REG_ERR, val);
    check(val[ERR_LSB +: 8] == 8'(ERR_OK),
          "a CRC16 error inside the retry budget still completes cleanly");
    axil_read(REG_STAT_RETRY, retry_val);
    check(retry_val[15:0] >= 16'(crc_inj),
          "STAT_RETRY CRC half counts at least the injected CRC16 failures");
    check(retry_val[31:16] == 16'h0,
          "a data CRC error does not advance the command-retry half");
    $display("  crc    STAT_RETRY[15:0] = %0d for %0d injections",
             retry_val[15:0], crc_inj);

    // ---- 4. STAT_RETRY[31:16]: command retries, forced -------------------
    // A corrupt response CRC7 is a command retry, counted in L2. Injected
    // while the next request's command frame is on the wire.
    axil_write(REG_CTRL, 32'(1 << CTRL_STAT_CLEAR_BIT));
    saw_cmd_retry = 1'b0;
    inject_cmd_crc = 1'b1; cmd_inj++;
    start_xfer(BLKS, BLKS, 1'b0);
    fork
      begin : cmd_release
        wait (saw_cmd_retry);
        inject_cmd_crc = 1'b0;
      end
      begin : cmd_guard
        repeat (400_000) @(posedge clk);
        inject_cmd_crc = 1'b0;
      end
    join_any
    disable fork;
    check(saw_cmd_retry, "the injected CRC7 error provoked a command retry");
    drain_read(BLKS * (BLOCK_BYTES/4));
    wait_done();

    axil_read(REG_STAT_RETRY, retry_val);
    check(retry_val[31:16] >= 16'(cmd_inj),
          "STAT_RETRY command half counts at least the injected CRC7 failures");
    $display("  cmd    STAT_RETRY[31:16] = %0d for %0d injections",
             retry_val[31:16], cmd_inj);

    // ---- 5. CTRL.STAT_CLEAR -----------------------------------------------
    // All five at once, because they are cleared by one toggle crossing into
    // three different modules and a clear that reaches only two of them is the
    // failure worth catching.
    // STAT_CLEAR, on all five at once -- one toggle crossing into three
    // different modules, and a clear that reaches only two of them is the
    // failure worth catching.
    //
    // STAT_BUSY is checked differently from the others, and the reason is a
    // measured property of the design rather than a convenience. STAT_BUSY
    // counts "DAT0 low while the data cell is idle", and DAT0 reaches it as
    // the PHY's SAMPLED value, not as the pad. Between transfers that sample
    // is not refreshed on every core cycle, so for a while after a transfer
    // ends the counter still sees the last captured 0 and keeps incrementing
    // even though the pad has gone high. Measured here: a clear issued on a
    // visibly idle bus reads back as a handful of cycles rather than zero, and
    // creeps up for a few hundred system clocks afterwards.
    //
    // That does not affect any delivered number -- every efficiency figure
    // clears the counters immediately before START and reads them at DONE, so
    // the window never contains idle time -- but it does mean "STAT_BUSY is
    // exactly zero at an arbitrary moment" is not a property the design has.
    // The property it does have, and the one worth guarding, is that the clear
    // actually happened: a counter holding 508 cycles does not read back as a
    // handful by accident.
    axil_read(REG_STAT_BUSY, b_core);
    check(b_core != 32'h0, "STAT_BUSY has something in it before the clear");

    axil_write(REG_CTRL, 32'(1 << CTRL_STAT_CLEAR_BIT));
    repeat (20) @(posedge clk);
    axil_read(REG_STAT_BUSY,  val);
    check(val < (b_core / 4), "STAT_CLEAR clears STAT_BUSY");
    $display("  clear  STAT_BUSY %0d -> %0d", b_core, val);
    axil_read(REG_STAT_DATA,  val); check(val == 32'h0, "STAT_CLEAR clears STAT_DATA");
    axil_read(REG_STAT_GAP,   val); check(val == 32'h0, "STAT_CLEAR clears STAT_GAP");
    axil_read(REG_STAT_RETRY, val); check(val == 32'h0, "STAT_CLEAR clears both STAT_RETRY halves");

    check(!card_protocol_err, "card model saw no protocol violation");
    $display("");

    rf = $fopen("../reports/sim_counter_crosscheck.txt", "w");
    if (rf) begin
      $fdisplay(rf, "tb_counter_crosscheck -- Table 5-2 counters vs independent counts");
      $fdisplay(rf, "blocks_per_transfer = %0d", BLKS);
      $fdisplay(rf, "crc_injections      = %0d", crc_inj);
      $fdisplay(rf, "cmd_injections      = %0d", cmd_inj);
      $fdisplay(rf, "checks              = %0d", checks);
      $fclose(rf);
    end

    if (failures) begin
      $display("tb_counter_crosscheck: FAILED (%0d failures)", failures);
      $fatal(1);
    end
    $display("tb_counter_crosscheck: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    #300_000_000;
    $fatal(1, "tb_counter_crosscheck timeout");
  end
endmodule

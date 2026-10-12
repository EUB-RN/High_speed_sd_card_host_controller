`timescale 1ns/1ps

// Functional coverage closure.
//
// A green regression says that whatever ran, passed. It does not say what ran.
// This test answers the second question for the four lists the specification
// writes down -- Table 6-2's command set, Table 5-3's error codes, Table 7-1's
// observable bus and speed outcomes, and R-DEG-1's divisor range -- and FAILS
// when a bin nobody reached is one the specification requires.
//
// That last part is what makes it a test rather than a report. Coverage that
// only prints is coverage nobody reads; coverage that fails the build is a
// ratchet, and the number in COV_REQUIRED below only ever goes up.
//
// The bins and their names live in common/cov/ultra_sd_cov.svh, together with
// the reason there is no `covergroup` in this project.
//
// HOW THE HARD BINS ARE REACHED
//
// Most of the command bins fall out of the initialisation ladder and one read
// and one write. The interesting ones are the error codes, because a healthy
// card never produces them:
//
//   ERR_NO_CARD       start a transfer with sd_cd deasserted
//   ERR_RANGE         ask for blocks past CARD_BLK (R-FUNC-4)
//   ERR_PROTOCOL      ask for zero blocks
//   ERR_DAT_CRC       inject a read data-CRC fault until the retries run out
//   ERR_WR_CRC_TOKEN  inject a negative write status token (R-FUNC-13)
//   ERR_CMD_TIMEOUT   make the card stop answering commands
//   ERR_DAT_TIMEOUT   make the card hold DAT0 low past PROG_TIMEOUT_CLK
//
// ERR_CMD_CRC, ERR_CMD_STATUS, ERR_INIT, ERR_UNSUPPORTED and ERR_CARD_STATE
// are reachable only from the initialisation ladder or from a card state this
// model does not produce, and are listed as known-open below rather than
// quietly dropped from the table.
module tb_coverage;
  import ultra_sd_pkg::*;

  `include "cov/ultra_sd_cov.svh"

  localparam int CARD_BLOCKS = 32;
  localparam int SYS_CLK_MHZ = 10;
  localparam int SYS_CLK_HZ  = SYS_CLK_MHZ * 1_000_000;

  int checks, failures;
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
    .CRC_RETRIES    (3),
    // The derived programming timeout is half a second of SD clocks; the
    // ERR_DAT_TIMEOUT bin cannot be reached in a simulation that waits for it.
    .PROG_TIMEOUT_CLK_P (20_000),
    .NAC_TIMEOUT_CLK_P  (20_000)
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
  logic inj_cmd_tmo = 0, inj_dat_crc = 0, inj_wr_crc = 0, inj_busy = 0;

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
    .inject_cmd_timeout_i (inj_cmd_tmo),
    .inject_cmd_crc_i     (1'b0),
    .inject_data_crc_i    (inj_dat_crc),
    .inject_write_crc_i   (inj_wr_crc),
    .inject_busy_stuck_i  (inj_busy),
    .protocol_error_o     (card_protocol_err),
    .last_cmd_o           (),
    .command_count_o      (),
    .bus_4bit_o           (),
    .high_speed_o         ()
  );

  // ---------------------------------------------------------------------------
  // Collection
  // ---------------------------------------------------------------------------
  int cov_cmd  [COV_N_CMD];
  int cov_err  [COV_N_ERR];
  int cov_width[2];          // 0 = 1-bit, 1 = 4-bit
  int cov_speed[3];          // SPEED_INIT, SPEED_DS, SPEED_HS
  int cov_div  [256];        // the CFG_CLK divisor actually in force

  // Commands are sampled where they are ACCEPTED, and at the command ENGINE
  // rather than at ultra_sd_protocol's block-layer port. The protocol module
  // has two requesters -- the init ladder and the data layer -- and only the
  // second one comes in through its req_* ports, so sampling there sees
  // CMD17/18/24/25/12/13 and none of the identification ladder. The engine is
  // the single point every command passes through.
  int cmd_bin;
  always @(posedge u_sd.sd_clk_core) begin
    if (rst_n && u_sd.u_cmd.u_engine.req_valid_i && u_sd.u_cmd.u_engine.req_ready_o) begin
      cmd_bin = cov_cmd_bin(u_sd.u_cmd.u_engine.req_index_i,
                            u_sd.u_cmd.u_engine.req_is_acmd_i);
      if (cmd_bin >= 0) cov_cmd[cmd_bin]++;
      // Every ACMD is CMD55 and then the command itself (Table 6-1). The engine
      // issues that prefix itself rather than being asked for it, so the CMD55
      // bin is credited here instead of waiting to see one arrive as a request.
      if (u_sd.u_cmd.u_engine.req_is_acmd_i) cov_cmd[13]++;
    end
  end

  // Error codes, sampled on the edge the core publishes one.
  logic [7:0] last_err_seen;
  always @(posedge clk) begin
    if (!rst_n) begin
      last_err_seen <= 8'hFF;
    end else begin
      if (u_sd.u_sysctl.err_o != last_err_seen) begin
        if (int'(u_sd.u_sysctl.err_o) < COV_N_ERR) cov_err[int'(u_sd.u_sysctl.err_o)]++;
        last_err_seen <= u_sd.u_sysctl.err_o;
      end
    end
  end

  // Bus width, speed mode and divisor: sampled continuously, because what
  // matters is that the state was ENTERED, not how long it lasted.
  always @(posedge clk) begin
    if (rst_n) begin
      cov_width[u_sd.u_sysctl.bus_wide_q]++;
      if (int'(u_sd.u_cmd.speed_o) < 3) cov_speed[int'(u_sd.u_cmd.speed_o)]++;
      cov_div[u_sd.cfg_clk]++;
    end
  end

  // ---------------------------------------------------------------------------
  // Stimulus plumbing
  // ---------------------------------------------------------------------------
  int  wr_left, wr_req;
  bit  wr_load;
  assign wr_tvalid = (wr_left > 0);
  assign wr_tlast  = (wr_left == 1);
  always @(posedge clk) begin
    if (!rst_n) begin
      wr_left  <= 0;
      wr_tdata <= 32'h0;
    end else if (wr_load) begin
      wr_left  <= wr_req;
    end else if (wr_tvalid && wr_tready) begin
      wr_left  <= wr_left - 1;
      wr_tdata <= wr_tdata + 32'h1;
    end
  end

  task automatic axil_write(input logic [7:0] addr, input logic [31:0] data);
    int t;
    @(negedge clk);
    awaddr = addr; wdata = data; wstrb = 4'hF;
    awvalid = 1; wvalid = 1; bready = 1;
    t = 0;
    while (!(awready && wready) && t < 50) begin @(posedge clk); #1; t++; end
    @(negedge clk); awvalid = 0; wvalid = 0;
    t = 0;
    while (!bvalid && t < 50) begin @(posedge clk); #1; t++; end
    @(negedge clk); bready = 0;
  endtask

  task automatic axil_read(input logic [7:0] addr, output logic [31:0] data);
    int t;
    @(negedge clk);
    araddr = addr; arvalid = 1; rready = 1;
    t = 0;
    while (!arready && t < 50) begin @(posedge clk); #1; t++; end
    @(posedge clk); #1;
    @(negedge clk); arvalid = 0;
    t = 0;
    while (!rvalid && t < 50) begin @(posedge clk); #1; t++; end
    data = rdata;
    @(negedge clk); rready = 0;
  endtask

  task automatic xfer(input logic dir, input int lba, input int blocks,
                      output logic [7:0] err);
    logic [31:0] v;
    int p;
    @(negedge clk);
    wr_req  = dir ? blocks * (BLOCK_BYTES/4) : 0;
    wr_load = 1'b1;
    @(negedge clk);
    wr_load = 1'b0;

    axil_write(REG_LBA, 32'(lba));
    // BLOCKS and XFER are separate registers (Table 5-1, 0x14 and 0x18). They
    // used to share one word, so one write set both; now it takes two, and
    // both have to land before CTRL.START because that is the write that
    // latches them (R-IF-3).
    axil_write(REG_BLOCKS, 32'(blocks));
    axil_write(REG_XFER, 32'(dir) << XFER_DIR_BIT);
    axil_write(REG_CTRL, 32'(1 << CTRL_START_BIT));

    p = 0;
    do begin axil_read(REG_STATUS, v); p++; end
    while (v[STATUS_DONE_BIT] && (p < 50_000));
    p = 0;
    do begin axil_read(REG_STATUS, v); p++; end
    while (!v[STATUS_DONE_BIT] && (p < 500_000));
    if (p >= 500_000) begin
      failures++;
      $display("FAIL: transfer hung (dir=%b lba=%0d blocks=%0d) after \"%s\"",
               dir, lba, blocks, phase_name);
    end
    axil_read(REG_ERR, v);
    err = v[ERR_LSB +: 8];
    repeat (200) @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------
  // Required bins. The ratchet: this list only grows.
  // ---------------------------------------------------------------------------
  // Commands: every row of Table 6-2 that this environment can reach.
  localparam int N_REQ_CMD = 17;

  // Error codes this environment can produce. The five that are missing are
  // named here so that "not covered" is a statement rather than an omission:
  //
  //   ERR_CMD_CRC (0x02)     needs a response whose CRC7 is wrong AND whose
  //                          retries are exhausted; the model can corrupt one
  //                          response, not every retry of it.
  //   ERR_CMD_STATUS (0x03)  needs the card to set an error bit in R1.
  //   ERR_INIT (0x08)        needs ACMD41 to never leave busy.
  //   ERR_UNSUPPORTED (0x09) needs an SDSC card or a card refusing 4-bit.
  //   ERR_CARD_STATE (0x0B)  needs CMD13 to report an unexpected state.
  //
  // All five are card behaviours the model does not implement. Adding them is
  // model work, not core work, and it is the next thing this directory wants.
  localparam int N_REQ_ERR = 8;
  int req_err [N_REQ_ERR];

  string phase_name = "start";
  int i, hit, miss;
  logic [7:0] err;
  logic [31:0] val;
  int t;

  initial begin
    checks = 0; failures = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    rd_tready = 1; wr_req = 0; wr_load = 0;
    for (i = 0; i < COV_N_CMD; i++) cov_cmd[i] = 0;
    for (i = 0; i < COV_N_ERR; i++) cov_err[i] = 0;
    cov_width[0] = 0; cov_width[1] = 0;
    for (i = 0; i < 3; i++)   cov_speed[i] = 0;
    for (i = 0; i < 256; i++) cov_div[i]   = 0;

    req_err[0] = 0;   // ERR_OK
    req_err[1] = 1;   // ERR_CMD_TIMEOUT
    req_err[2] = 4;   // ERR_DAT_TIMEOUT
    req_err[3] = 5;   // ERR_DAT_CRC
    req_err[4] = 6;   // ERR_WR_CRC_TOKEN
    req_err[5] = 7;   // ERR_NO_CARD
    req_err[6] = 10;  // ERR_RANGE
    req_err[7] = 12;  // ERR_PROTOCOL

    // ---- no card: ERR_NO_CARD, before the ladder ever runs ----------------
    sd_cd = 1;                       // ACTIVE LOW, so 1 = absent
    #1 rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;
    repeat (200) @(posedge clk);
    phase_name = "no card";
    xfer(1'b0, 0, 1, err);
    check(err == 8'(ERR_NO_CARD), "no card gives ERR_NO_CARD");

    // ---- insert the card: the whole ladder, 4-bit, High Speed -------------
    sd_cd = 0;
    t = 0;
    do begin axil_read(REG_STATUS, val); t++; end
    while (!val[STATUS_CARD_RDY_BIT] && t < 60000);
    check(val[STATUS_CARD_RDY_BIT], "card reaches ready after insertion");
    check(val[STATUS_BUS_WIDTH_LSB] == 1'b1, "the ladder reached 4-bit");

    // ---- the ordinary paths ----------------------------------------------
    xfer(1'b1, 0, 1, err);  check(err == 8'(ERR_OK), "single write");
    xfer(1'b0, 0, 1, err);  check(err == 8'(ERR_OK), "single read");
    xfer(1'b1, 4, 3, err);  check(err == 8'(ERR_OK), "multi write");
    xfer(1'b0, 4, 3, err);  check(err == 8'(ERR_OK), "multi read");

    // ---- argument refusals -------------------------------------------------
    // The range check is against CARD_BLK as the ladder parsed it out of the
    // CSD, not against this testbench's idea of the card's size: if those two
    // ever disagree, the bug is in the CSD parsing and asking the register is
    // what finds it.
    // CSD v2.0 states capacity in 512 KB units, so C_SIZE cannot express 32
    // blocks: the model rounds up to the next 1024-sector unit and the core
    // reports what the CSD said. Check the rounding rule rather than the
    // model's BLOCK_COUNT -- asserting the latter would be asserting that the
    // core disagrees with the card.
    axil_read(REG_CARD_BLK, val);
    check(val == 32'(((CARD_BLOCKS + 1023) / 1024) * 1024),
          $sformatf("CARD_BLK is the CSD capacity rounded to a 1024-sector unit (%0d)",
                    val));
    xfer(1'b0, val - 32'd1, 4, err);
    check(err == 8'(ERR_RANGE), "beyond capacity gives ERR_RANGE");
    xfer(1'b0, 0, 0, err);
    check(err == 8'(ERR_PROTOCOL), "zero blocks gives ERR_PROTOCOL");

    // ---- injected faults ---------------------------------------------------
    phase_name = "read CRC injection";
    inj_dat_crc = 1; xfer(1'b0, 0, 2, err); inj_dat_crc = 0;
    check(err == 8'(ERR_DAT_CRC), "persistent read CRC gives ERR_DAT_CRC");
    xfer(1'b0, 0, 1, err);

    phase_name = "write token injection";
    inj_wr_crc = 1; xfer(1'b1, 0, 2, err); inj_wr_crc = 0;
    check(err == 8'(ERR_WR_CRC_TOKEN), "rejected write token gives ERR_WR_CRC_TOKEN");
    xfer(1'b1, 0, 1, err);

    phase_name = "command timeout injection";
    inj_cmd_tmo = 1; xfer(1'b0, 0, 1, err); inj_cmd_tmo = 0;
    check(err == 8'(ERR_CMD_TIMEOUT), "silent card gives ERR_CMD_TIMEOUT");
    xfer(1'b0, 0, 1, err);

    phase_name = "stuck busy injection";
    inj_busy = 1; xfer(1'b1, 0, 1, err); inj_busy = 0;
    check(err == 8'(ERR_DAT_TIMEOUT), "stuck busy gives ERR_DAT_TIMEOUT");
    xfer(1'b1, 0, 1, err);

    // ---- R-DEG-1: the divisor is runtime-settable over its whole range ----
    // Writing CFG_CLK and then running a transfer at that divisor is the only
    // honest way to cover this: a register that accepts a value it does not
    // act on would pass a read-back check.
    phase_name = "divisor 4";
    axil_write(REG_CFG_CLK, 32'd4);   xfer(1'b0, 0, 1, err);
    check(err == 8'(ERR_OK), "a transfer completes at divisor 4");
    phase_name = "divisor 16";
    axil_write(REG_CFG_CLK, 32'd16);  xfer(1'b0, 0, 1, err);
    check(err == 8'(ERR_OK), "a transfer completes at divisor 16");
    phase_name = "divisor 250";
    axil_write(REG_CFG_CLK, 32'd250); xfer(1'b0, 0, 1, err);
    check(err == 8'(ERR_OK), "a transfer completes at the identification divisor");
    axil_write(REG_CFG_CLK, 32'd2);

    // ---- R-DEG-4: forced 1-bit and forced Default Speed --------------------
    // These exist for cards that misreport themselves, and they are the only
    // way to reach the 1-bit and Default Speed bins once a healthy card has
    // negotiated its way out of them.
    // CFG_PHY is its own register (Table 5-1, 0x20), so setting the force
    // bits cannot disturb the clock divisor. It used to share a word with
    // CFG_CLK, and this write is what found that: a plain 32-bit write of the
    // PHY field zeroed the divisor, and divisor 0 is not a clock, so every
    // transfer after it hung. That packing is gone.
    axil_write(REG_CFG_PHY, 32'((1 << CFG_PHY_FORCE_1BIT) |
                                (1 << CFG_PHY_FORCE_DS)));
    axil_read(REG_CFG_PHY, val);
    check(val[CFG_PHY_FORCE_1BIT] && val[CFG_PHY_FORCE_DS],
          $sformatf("CFG_PHY holds the force bits (read 0x%08x)", val));
    axil_write(REG_CTRL, 32'(1 << CTRL_SOFT_RESET_BIT));

    // WAIT FOR CARD_READY TO DROP BEFORE WAITING FOR IT TO RISE. The ladder
    // takes a while to notice the reset, and a poll that starts immediately
    // reads the READY left over from the PREVIOUS initialisation and returns
    // at once -- with the old bus width and speed still in STATUS, which is
    // what made this look like FORCE_1BIT being ignored. Same trap as
    // STATUS.DONE in xfer() above.
    t = 0;
    do begin axil_read(REG_STATUS, val); t++; end
    while (val[STATUS_CARD_RDY_BIT] && t < 60000);
    check(t < 60000, "SOFT_RESET drops CARD_READY");

    t = 0;
    do begin axil_read(REG_STATUS, val); t++; end
    while (!val[STATUS_CARD_RDY_BIT] && t < 60000);
    check(val[STATUS_CARD_RDY_BIT], "the card re-initialises under FORCE_1BIT");
    check(val[STATUS_BUS_WIDTH_LSB] == 1'b0, "FORCE_1BIT is honoured in STATUS");
    check(val[STATUS_SPEED_LSB +: 2] == 2'(SPEED_DS), "FORCE_DS is honoured in STATUS");
    phase_name = "forced 1-bit DS";
    xfer(1'b0, 0, 1, err);
    check(err == 8'(ERR_OK), "a 1-bit Default Speed transfer completes");

    // ---- the report --------------------------------------------------------
    $display("");
    $display("  ---- command coverage (Table 6-2) ----");
    hit = 0;
    for (i = 0; i < COV_N_CMD; i++) begin
      $display("    %-24s %0d", cov_cmd_name(i), cov_cmd[i]);
      if (cov_cmd[i] > 0) hit++;
    end
    check(hit == N_REQ_CMD,
          $sformatf("every Table 6-2 command was issued (%0d of %0d)", hit, N_REQ_CMD));

    $display("");
    $display("  ---- error-code coverage (Table 5-3) ----");
    for (i = 0; i < COV_N_ERR; i++)
      $display("    %-18s %0d", cov_err_name(i), cov_err[i]);
    miss = 0;
    for (i = 0; i < N_REQ_ERR; i++)
      if (cov_err[req_err[i]] == 0) begin
        miss++;
        $display("    MISSING: %s", cov_err_name(req_err[i]));
      end
    check(miss == 0,
          $sformatf("every reachable Table 5-3 code was produced (%0d missing)", miss));

    $display("");
    $display("  ---- bus width / speed / divisor ----");
    $display("    1-bit %0d   4-bit %0d", cov_width[0], cov_width[1]);
    $display("    SPEED_INIT %0d   SPEED_DS %0d   SPEED_HS %0d",
             cov_speed[0], cov_speed[1], cov_speed[2]);
    check(cov_width[0] > 0 && cov_width[1] > 0, "both bus widths were entered");
    check(cov_speed[0] > 0 && cov_speed[1] > 0 && cov_speed[2] > 0,
          "all three speed modes were entered");

    hit = 0;
    for (i = 0; i < 256; i++) if (cov_div[i] > 0) begin
      hit++;
      $display("    divisor %0d: %0d cycles", i, cov_div[i]);
    end
    check(hit >= 4, $sformatf("at least four distinct divisors were in force (%0d)", hit));

    $display("");
    check(!card_protocol_err, "the card model saw no protocol violation of ours");

    if (failures) begin
      $display("tb_coverage: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_coverage: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "tb_coverage timeout");
  end
endmodule

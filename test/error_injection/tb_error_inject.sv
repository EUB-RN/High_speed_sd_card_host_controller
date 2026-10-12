`timescale 1ns/1ps

// The error paths, driven by a card that is made to misbehave on purpose.
//
// This is the half of the design that does the most work and gets the least
// exercise. A real card does not produce CRC errors on demand, so the bench
// cannot reach these paths at all and the tier run has RETRY = 0 and
// ERR_CODE = 0 every time -- which says the recovery logic was never asked a
// question, not that it answered one. sd_card_model has had five injection
// inputs all along and tb_sd_card_model drives every one of them, but that test
// checks the MODEL injects; nothing checked what the core does about it.
//
// Four scenarios, one per fault, each asking for a specific code from Table 5-3:
//
//   crc16_read_error   a corrupted data CRC on a read. The core must retry, and
//                      when the retries run out report ERR_DAT_CRC. The retry
//                      counter must also have moved: a design that reports the
//                      error without having tried is a different design.
//   crc_status_reject  the card answers a written block with a "rejected" CRC
//                      status token instead of "accepted" -> ERR_WR_CRC_TOKEN.
//   response_timeout   the card never answers a command -> ERR_CMD_TIMEOUT.
//   dat_stuck_busy     the card holds DAT0 low past the programming timeout
//                      -> ERR_DAT_TIMEOUT.
//
// Every scenario ends by clearing the fault and running a clean transfer. That
// last step is the real test: an error path that reports the right code and
// leaves the core wedged has not recovered, it has just failed politely.
module tb_error_inject;
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
    .CRC_RETRIES    (3),
    // The derived programming timeout is half a second of SD clocks, which at
    // this testbench's clock is a second of simulated time -- so dat_stuck_busy
    // could never reach it and the scenario could not be written. Shortened to
    // something a simulation can wait for; the ratio to the card model's
    // WRITE_BUSY_CYCLES (8) is still three orders of magnitude, so a healthy
    // card is nowhere near it.
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
  logic inj_cmd_tmo = 1'b0, inj_dat_crc = 1'b0, inj_wr_crc = 1'b0, inj_busy = 1'b0;

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

  // Run one transfer and give back what the core said about it. A scenario is
  // then three lines: set the fault, call this, read the verdict.
  //
  // No fork here. The streams need no thread of their own -- the read sink is
  // tready tied high and the write source is a continuous assign off wr_left --
  // so polling STATUS in one loop is the whole of it. (Icarus also aborts on
  // fork/join_any inside an automatic task, which is how that was discovered.)
  // WHERE A WEDGED SCENARIO IS WEDGED. +eidbg.
  //
  // Every scenario here is a recovery path, and when one of them stops making
  // progress the only thing the poll loop can say is "no DONE in 400000
  // reads". That is not a diagnosis. Printing the block FSM's step next to the
  // line cell and the card's own DAT state, on change, says which of the three
  // is waiting for which -- the same probe that placed tb_line_card's bugs.
  int ei_blk = -1, ei_cell = -1, ei_cdat = -1, ei_rdy = -1;
  always @(posedge clk) begin
    if (rst_n && $test$plusargs("eidbg") &&
        ((int'(u_sd.u_block.step_q) != ei_blk) ||
         (int'(u_sd.u_line.cell_q)  != ei_cell) ||
         (int'(u_sd.u_block.wr_block_ready_i) != ei_rdy) ||
         (int'(u_card.dat_tx_state_q) != ei_cdat))) begin
      $display("      [%0t] blk=%0d cell=%0d card_dat=%0d post=%0d retry=%0d busy=%b wr_rdy=%b lvl=%0d wp=%0d wpub=%0d wprd=%0d rp=%0d full=%b wrstn=%b wen=%b tv=%b tr=%b",
               $time, u_sd.u_block.step_q, u_sd.u_line.cell_q,
               u_card.dat_tx_state_q, u_sd.u_block.post_q,
               u_sd.u_block.retry_q, u_sd.u_line.card_busy_o,
               u_sd.u_block.wr_block_ready_i,
               u_sd.u_axi.u_axis_rx.sd_rd_level,
               u_sd.u_axi.u_axis_rx.u_fifo.wptr_bin,
               u_sd.u_axi.u_axis_rx.u_fifo.wptr_pub,
               u_sd.u_axi.u_axis_rx.u_fifo.wptr_bin_rd_q,
               u_sd.u_axi.u_axis_rx.u_fifo.rptr_bin,
               u_sd.u_axi.u_axis_rx.u_fifo.wr_full,
               u_sd.u_axi.u_axis_rx.u_fifo.wr_rst_n,
               u_sd.u_axi.u_axis_rx.u_fifo.wr_en,
               wr_tvalid, wr_tready);
      ei_blk  = int'(u_sd.u_block.step_q);
      ei_cell = int'(u_sd.u_line.cell_q);
      ei_cdat = int'(u_card.dat_tx_state_q);
      ei_rdy  = int'(u_sd.u_block.wr_block_ready_i);
    end
  end

  task automatic xfer(input logic dir, input int lba, input int blocks,
                      output logic [7:0] err);
    logic [31:0] v;
    int p;
    // Arm the write source as part of the transfer, so a scenario cannot forget
    // to and then read the silence as success.
    //
    // DRIVE wr_load ON THE NEGEDGE. It used to be set, then `@(posedge clk)`,
    // then cleared -- and clearing it immediately after the edge races the
    // always_ff that is supposed to sample it. Icarus resolved that race the
    // wrong way every time, so wr_left was never loaded, wr_tvalid never rose,
    // and the write FIFO stayed empty: the block layer then sat in S_WR_ARM
    // waiting for a block that no one was sending, which is the hang the
    // crc_status_reject and dat_stuck_busy scenarios were recorded as
    // "OPEN, cause unknown". Nothing was wrong with the core -- the scenarios
    // had never managed to start a write at all. (crc16_read_error was
    // unaffected because a read passes wr_req = 0.)
    @(negedge clk);
    wr_req  = dir ? blocks * (BLOCK_BYTES/4) : 0;
    wr_load = 1'b1;
    @(negedge clk);
    wr_load = 1'b0;

    axil_write(REG_CTRL, 32'(1 << CTRL_STAT_CLEAR_BIT));
    axil_write(REG_LBA, 32'(lba));
    // BLOCKS and XFER are separate registers (Table 5-1, 0x14 and 0x18). They
    // used to share one word, so one write set both; now it takes two, and
    // both have to land before CTRL.START because that is the write that
    // latches them (R-IF-3).
    axil_write(REG_BLOCKS, 32'(blocks));
    axil_write(REG_XFER, 32'(dir) << XFER_DIR_BIT);
    axil_write(REG_CTRL, 32'(1 << CTRL_START_BIT));

    // WAIT FOR DONE TO CLEAR BEFORE WAITING FOR IT TO SET.
    //
    // STATUS.DONE is cleared by accept_i -- ultra_sd_block raising accept_o when
    // it takes the request -- and `go` reaches it through a two-flop
    // synchroniser into cmd_clk, which at the tier divisor is twenty system
    // clocks per edge. A poll that starts right after the START write therefore
    // reads the PREVIOUS transfer's DONE and returns immediately, with the
    // previous transfer's error code. Every scenario after the first then
    // passes or fails on a stale answer.
    //
    // bench_core does not trip on this only because its X_RUN streams the
    // payload before it ever polls, by which time DONE has long since cleared.
    p = 0;
    quiet = 1;
    do begin
      axil_read(REG_STATUS, v);
      p++;
    end while (v[STATUS_DONE_BIT] && (p < 20000));
    check(p < 20000, "the core took the request (DONE cleared)");

    p = 0;
    do begin
      axil_read(REG_STATUS, v);
      p++;
    end while (!v[STATUS_DONE_BIT] && (p < 400000));
    quiet = 0;
    check(p < 400000, "the transfer reached DONE rather than hanging");

    axil_read(REG_ERR, v);
    err = v[ERR_LSB +: 8];
    axil_read(REG_STAT_RETRY, v);
    $display("      xfer dir=%b blocks=%0d -> err=%02h beats=%0d retry=%0d polls=%0d",
             dir, blocks, err, beat_cnt, v, p);
  endtask

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
  int          t;

  // The write stream. Content is irrelevant to these scenarios -- what is being
  // tested is the protocol around the payload -- so it is a counter, and nothing
  // compares it. tlast lands on the beat the request's own beat count says is
  // last, which is what R-IF-6 promises and what wr_proto checks.
  // ONE driver for wr_left. It was briefly written from the initial block as
  // well as here, which is legal Verilog and a race: the source would arm, or
  // not, depending on which process the simulator ran first, and a write that
  // never streams looks exactly like a write the card accepted.
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

  // Beats actually moved by the last transfer, counted here rather than taken
  // on trust: a write that never streamed and a write the card accepted look
  // the same from the error code alone.
  int beat_cnt;
  always @(posedge clk) begin
    if (!rst_n || wr_load) beat_cnt <= 0;
    else if ((rd_tvalid && rd_tready) || (wr_tvalid && wr_tready))
      beat_cnt <= beat_cnt + 1;
  end

  logic [7:0] err;

  initial begin
    checks = 0; failures = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    rd_tready = 1; wr_req = 0; wr_load = 0;

    #1 rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;
    sd_cd = 0;

    t = 0;
    quiet = 1;
    do begin
      axil_read(REG_STATUS, val);
      t++;
    end while (!val[STATUS_CARD_RDY_BIT] && t < 30000);
    quiet = 0;
    check(val[STATUS_CARD_RDY_BIT], "card reaches ready after init");

    // ---- 1/4 crc16_read_error -------------------------------------------
    // The card corrupts the CRC16 of every block it sends. The core retries --
    // CRC_RETRIES of them -- and then has to give up with the code for a data
    // CRC failure, not a timeout and not silence.
    $display("-- 1/4 crc16_read_error --");
    inj_dat_crc = 1'b1;
    xfer(1'b0, 0, 2, err);
    check(err == 8'(ERR_DAT_CRC),
          $sformatf("a persistently bad data CRC reports ERR_DAT_CRC (got %02h)", err));
    axil_read(REG_STAT_RETRY, val);
    check(val != 32'd0, "the core actually retried before giving up");
    inj_dat_crc = 1'b0;
    xfer(1'b0, 0, 2, err);
    check(err == 8'(ERR_OK), "a clean read works once the fault is removed");

    // ---- 2/4 crc_status_reject ------------------------------------------
    // The card takes the block and then answers "rejected" in the CRC status
    // token. Nothing is wrong with the bus; the card is saying it did not like
    // what arrived, and that has its own code.
    $display("-- 2/4 crc_status_reject --");
    inj_wr_crc = 1'b1;
    xfer(1'b1, 0, 2, err);
    check(err == 8'(ERR_WR_CRC_TOKEN),
          $sformatf("a rejected write status reports ERR_WR_CRC_TOKEN (got %02h)", err));
    inj_wr_crc = 1'b0;
    xfer(1'b1, 0, 2, err);
    check(err == 8'(ERR_OK), "a clean write works once the fault is removed");

    // ---- 3/4 response_timeout -------------------------------------------
    // The card never answers the command at all. This is the one error the
    // command layer owns rather than the data layer, so the code comes from
    // ultra_sd_cmd's own retry ladder running out.
    $display("-- 3/4 response_timeout --");
    inj_cmd_tmo = 1'b1;
    xfer(1'b0, 0, 1, err);
    check(err == 8'(ERR_CMD_TIMEOUT),
          $sformatf("an unanswered command reports ERR_CMD_TIMEOUT (got %02h)", err));
    inj_cmd_tmo = 1'b0;
    xfer(1'b0, 0, 1, err);
    check(err == 8'(ERR_OK), "commands work again once the card answers");

    // ---- 4/4 dat_stuck_busy ----------------------------------------------
    // The card holds DAT0 low and never lets go. The host cannot tell this from
    // a very slow program except by the clock, which is exactly what
    // PROG_TIMEOUT_CLK is for.
    $display("-- 4/4 dat_stuck_busy --");
    inj_busy = 1'b1;
    xfer(1'b1, 0, 1, err);
    check(err == 8'(ERR_DAT_TIMEOUT),
          $sformatf("a card that never releases DAT0 reports ERR_DAT_TIMEOUT (got %02h)", err));
    inj_busy = 1'b0;
    xfer(1'b1, 0, 1, err);
    check(err == 8'(ERR_OK), "writes work again once the card releases DAT0");

    check(!card_protocol_err, "the card model saw no protocol violation of ours");

    if (failures) begin
      $display("tb_error_inject: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_error_inject: PASSED (%0d checks)", checks);
    $finish;
  end
  initial begin
    #200_000_000;
    $fatal(1, "tb_error_inject timeout");
  end
endmodule

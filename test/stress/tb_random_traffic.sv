`timescale 1ns/1ps

// Seeded random traffic against the behavioural card, scoreboarded end to end.
//
// WHY THIS IS NOT ANOTHER FUNCTIONAL TEST
//
// Every other testbench in this tree drives a sequence somebody chose. That is
// the right way to prove a specific requirement and the wrong way to find the
// case nobody thought of: the directed tests all start from an idle core, use
// round block counts, and let the streams run at full rate. The bugs that
// survive directed testing are the ones that need a particular ORDER -- a
// three-block write followed immediately by a one-block read from an
// overlapping LBA, with the sink stalling in the middle of the second block.
//
// So this test picks direction, block count, LBA and both backpressure
// patterns at random, runs a few hundred transfers of them back to back, and
// checks every byte against its own model of the card. The seed is printed and
// can be forced with `make random_traffic SEED=<n>`, so a failure is
// replayable exactly.
//
// WHAT IS CHECKED, AND WHY A SCOREBOARD RATHER THAN A PATTERN
//
// The usual trick is to write a counting pattern and check it comes back. That
// catches corruption but not displacement: a read that returns the right bytes
// from the wrong LBA passes, and so does a write that lands one block early.
// The scoreboard here keeps its own copy of every block this test has written
// and compares reads against THAT, so address arithmetic is covered as well as
// payload integrity (R-FUNC-4 range handling, and the LBA sequencing of L3).
//
// Covers R-IF-5, R-IF-6, R-IF-7, R-IF-8, R-FUNC-8, R-FUNC-11, and is the one
// place the design is asked to do several hundred different things in a row
// without being reset between them.
module tb_random_traffic;
  import ultra_sd_pkg::*;

  // The card model's store is the limit on how much address space is worth
  // randomising over; 64 blocks is enough for overlapping and adjacent
  // transfers without making the model enormous.
  localparam int CARD_BLOCKS   = 64;
  localparam int MAX_BLOCKS    = 4;
  localparam int WORDS_PER_BLK = BLOCK_BYTES / 4;

  localparam int SYS_CLK_MHZ = 10;
  localparam int SYS_CLK_HZ  = SYS_CLK_MHZ * 1_000_000;

  // Transfers per run. Long enough that ordering effects show up, short enough
  // that the regression stays usable; the nightly runs it with a bigger count.
  int unsigned n_xfers = 200;

  int checks, failures;
  logic quiet = 0;
  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin
      failures++;
      if (failures <= 20) $display("FAIL: %s", message);
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

  // ---------------------------------------------------------------------------
  // Scoreboard
  // ---------------------------------------------------------------------------
  // One entry per block this test has written, so a read can be checked
  // against what was actually put there rather than against a pattern.
  // `written` separates "we know what is here" from "the card model's
  // power-on fill is here", which is not something this test should assert on.
  logic [31:0] model [CARD_BLOCKS][WORDS_PER_BLK];
  bit          written [CARD_BLOCKS];

  // ---------------------------------------------------------------------------
  // Randomisation
  // ---------------------------------------------------------------------------
  int unsigned seed;
  int unsigned rd_stall_pct, wr_stall_pct;

  // Backpressure and starvation, re-rolled per transfer. 0 % is the easy case
  // the directed tests already cover; the interesting range is high, which is
  // exactly what R-IF-7 means by "arbitrary" and R-IF-8 by "arbitrarily slow".
  always @(posedge clk) begin
    if (!rst_n) rd_tready <= 1'b1;
    else        rd_tready <= ($urandom_range(99) >= rd_stall_pct);
  end

  // ---------------------------------------------------------------------------
  // Write source
  // ---------------------------------------------------------------------------
  // One driver, armed on the negedge: setting a load strobe and clearing it
  // right after the posedge races the always_ff that samples it, and the
  // simulator is free to resolve that race either way (tb_error_inject lost
  // three scenarios to exactly that).
  int  wr_left, wr_req;
  bit  wr_load;
  logic [31:0] wr_seed_word;
  bit          wr_stall;

  always @(posedge clk) begin
    if (!rst_n) wr_stall <= 1'b0;
    else        wr_stall <= ($urandom_range(99) < wr_stall_pct);
  end

  assign wr_tvalid = (wr_left > 0) && !wr_stall;
  assign wr_tlast  = (wr_left == 1);

  always @(posedge clk) begin
    if (!rst_n) begin
      wr_left  <= 0;
      wr_tdata <= 32'h0;
    end else if (wr_load) begin
      wr_left  <= wr_req;
      wr_tdata <= wr_seed_word;
    end else if (wr_tvalid && wr_tready) begin
      wr_left  <= wr_left - 1;
      // A counter seeded per transfer, so two transfers never carry the same
      // payload and a block delivered from the wrong one is visible.
      wr_tdata <= wr_tdata + 32'h0001_0001;
    end
  end

  // ---------------------------------------------------------------------------
  // Read sink: compares against the scoreboard as the beats arrive
  // ---------------------------------------------------------------------------
  bit          rd_checking;
  int          rd_lba_base;
  int          rd_word_idx;
  int          rd_mismatches;
  int          rd_beats_seen;
  bit          rd_last_seen;
  int          rd_beats_expected;

  always @(posedge clk) begin
    if (!rst_n) begin
      rd_word_idx   <= 0;
      rd_mismatches <= 0;
      rd_beats_seen <= 0;
      rd_last_seen  <= 1'b0;
    end else if (rd_checking && rd_tvalid && rd_tready) begin
      if (written[(rd_lba_base + (rd_word_idx / WORDS_PER_BLK)) % CARD_BLOCKS] &&
          (rd_tdata !== model[(rd_lba_base + (rd_word_idx / WORDS_PER_BLK)) % CARD_BLOCKS]
                            [rd_word_idx % WORDS_PER_BLK]))
        rd_mismatches <= rd_mismatches + 1;
      rd_word_idx   <= rd_word_idx + 1;
      rd_beats_seen <= rd_beats_seen + 1;
      // R-IF-6: tlast on the final beat of the request and nowhere else.
      if (rd_tlast) rd_last_seen <= 1'b1;
      if (rd_tlast && (rd_beats_seen + 1 != rd_beats_expected)) begin
        failures++;
        if (failures <= 20)
          $display("FAIL: tlast on beat %0d of %0d", rd_beats_seen + 1, rd_beats_expected);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Bus helpers
  // ---------------------------------------------------------------------------
  task automatic axil_write(input logic [7:0] addr, input logic [31:0] data);
    int t;
    @(negedge clk);
    awaddr = addr; wdata = data; wstrb = 4'hF;
    awvalid = 1; wvalid = 1; bready = 1;
    t = 0;
    while (!(awready && wready) && t < 50) begin @(posedge clk); #1; t++; end
    if (t >= 50) begin failures++; $display("FAIL: AXI-Lite write handshake"); end
    @(negedge clk); awvalid = 0; wvalid = 0;
    t = 0;
    while (!bvalid && t < 50) begin @(posedge clk); #1; t++; end
    if (!(bvalid && bresp == 2'b00)) begin failures++; $display("FAIL: AXI-Lite write response"); end
    @(negedge clk); bready = 0;
  endtask

  task automatic axil_read(input logic [7:0] addr, output logic [31:0] data);
    int t;
    @(negedge clk);
    araddr = addr; arvalid = 1; rready = 1;
    t = 0;
    while (!arready && t < 50) begin @(posedge clk); #1; t++; end
    if (t >= 50) begin failures++; $display("FAIL: AXI-Lite read-address handshake"); end
    @(posedge clk); #1;
    @(negedge clk); arvalid = 0;
    t = 0;
    while (!rvalid && t < 50) begin @(posedge clk); #1; t++; end
    data = rdata;
    if (!(rvalid && rresp == 2'b00)) begin failures++; $display("FAIL: AXI-Lite read response"); end
    @(negedge clk); rready = 0;
  endtask

  // ---------------------------------------------------------------------------
  // One transfer
  // ---------------------------------------------------------------------------
  task automatic run_xfer(input bit dir, input int lba, input int blocks,
                          output logic [7:0] err);
    logic [31:0] v;
    int p, b, w;
    int beats;

    beats = blocks * WORDS_PER_BLK;

    @(negedge clk);
    if (dir) begin
      wr_req       = beats;
      wr_seed_word = {16'(lba), 16'(blocks)} ^ 32'hA5A5_0000;
      wr_load      = 1'b1;
    end else begin
      rd_lba_base       = lba;
      rd_beats_expected = beats;
      rd_checking       = 1'b1;
    end
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

    // DONE is cleared by the block layer accepting the request, which arrives
    // through a two-flop synchroniser; polling before it clears reads the
    // PREVIOUS transfer's verdict.
    p = 0;
    do begin axil_read(REG_STATUS, v); p++; end
    while (v[STATUS_DONE_BIT] && (p < 50_000));
    if (p >= 50_000) begin failures++; $display("FAIL: request not accepted"); end

    p = 0;
    do begin axil_read(REG_STATUS, v); p++; end
    while (!v[STATUS_DONE_BIT] && (p < 500_000));
    if (p >= 500_000) begin failures++; $display("FAIL: transfer hung"); end

    axil_read(REG_ERR, v);
    err = v[ERR_LSB +: 8];

    // DONE IS THE CARD'S SIDE FINISHING, NOT THE STREAM'S.
    //
    // STATUS.DONE is raised when the block layer is finished with the card.
    // The last beats of the last block are still in the read FIFO at that
    // point, and with the sink stalling up to 90 % of cycles they take over a
    // thousand clocks to come out. Waiting a fixed number of cycles here --
    // the first version waited 64 -- counts a partial frame and then attributes
    // the rest of it to the NEXT transfer, which is what produced "235 of 256
    // beats" and then "tlast on beat 526 of 512" two transfers later. None of
    // that was the design.
    //
    // tlast is the real end of the frame, so wait for that, bounded.
    if (!dir) begin
      p = 0;
      while (!rd_last_seen && (p < 2_000_000)) begin @(posedge clk); p++; end
      if (p >= 2_000_000) begin
        failures++;
        $display("FAIL: read stream never produced tlast");
      end
      @(posedge clk);
      rd_checking = 1'b0;
    end

    // Update the model only once the card has said it took the data.
    if (dir && (err == 8'(ERR_OK))) begin
      for (b = 0; b < blocks; b++) begin
        for (w = 0; w < WORDS_PER_BLK; w++)
          model[(lba + b) % CARD_BLOCKS][w] =
            ({16'(lba), 16'(blocks)} ^ 32'hA5A5_0000) +
            32'(b * WORDS_PER_BLK + w) * 32'h0001_0001;
        written[(lba + b) % CARD_BLOCKS] = 1'b1;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  int unsigned i;
  int          lba, blocks;
  bit          dir;
  logic [7:0]  err;
  logic [31:0] val;
  int          t;
  int          n_reads, n_writes;
  int unsigned dummy_rand;

  initial begin
    checks = 0; failures = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0;
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    wr_req = 0; wr_load = 0; rd_checking = 0;
    rd_lba_base = 0; rd_beats_expected = 0;
    rd_stall_pct = 0; wr_stall_pct = 0;
    n_reads = 0; n_writes = 0;
    for (int bi = 0; bi < CARD_BLOCKS; bi++) written[bi] = 1'b0;

    // Reproducibility is the whole point of a random test: the seed goes in
    // the log, and `make random_traffic SEED=<n>` replays the exact run.
    if (!$value$plusargs("seed=%d", seed)) seed = 32'hC0FFEE01;
    // Icarus has no void'(), and $urandom(seed) reseeds the generator for this
    // process whichever way its return value is discarded.
    dummy_rand = $urandom(seed);
    if ($value$plusargs("xfers=%d", i)) n_xfers = i;
    $display("tb_random_traffic: seed = %0d, %0d transfers", seed, n_xfers);

    #1 rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;
    sd_cd = 0;

    t = 0;
    do begin axil_read(REG_STATUS, val); t++; end
    while (!val[STATUS_CARD_RDY_BIT] && t < 30000);
    check(val[STATUS_CARD_RDY_BIT], "card reaches ready after init");

    for (i = 0; i < n_xfers; i++) begin
      dir          = ($urandom_range(1) == 1);
      blocks       = $urandom_range(MAX_BLOCKS - 1) + 1;
      lba          = $urandom_range(CARD_BLOCKS - blocks - 1);
      rd_stall_pct = $urandom_range(90);
      wr_stall_pct = $urandom_range(90);

      run_xfer(dir, lba, blocks, err);
      if (dir) n_writes++; else n_reads++;

      check(err == 8'(ERR_OK),
            $sformatf("xfer %0d (%s lba=%0d blocks=%0d rd_stall=%0d wr_stall=%0d) ERR_OK, got %02h",
                      i, dir ? "write" : "read", lba, blocks,
                      rd_stall_pct, wr_stall_pct, err));

      if (!dir) begin
        check(rd_last_seen, $sformatf("xfer %0d: tlast arrived", i));
        check(rd_beats_seen == blocks * WORDS_PER_BLK,
              $sformatf("xfer %0d: %0d of %0d beats delivered",
                        i, rd_beats_seen, blocks * WORDS_PER_BLK));
      end

      // The scoreboard is checked continuously by the sink; this is the
      // per-transfer verdict on it.
      check(rd_mismatches == 0,
            $sformatf("xfer %0d: %0d payload mismatches against the scoreboard",
                      i, rd_mismatches));

      @(negedge clk);
      rd_word_idx   = 0;
      rd_beats_seen = 0;
      rd_mismatches = 0;
      rd_last_seen  = 1'b0;
    end

    check(!card_protocol_err, "the card model saw no protocol violation of ours");

    $display("tb_random_traffic: %0d reads, %0d writes", n_reads, n_writes);
    if (failures) begin
      $display("tb_random_traffic: FAILED (%0d/%0d)  seed=%0d", failures, checks, seed);
      $fatal(1);
    end
    $display("tb_random_traffic: PASSED (%0d checks)  seed=%0d", checks, seed);
    $finish;
  end

  initial begin
    #2_000_000_000;
    $fatal(1, "tb_random_traffic timeout");
  end
endmodule

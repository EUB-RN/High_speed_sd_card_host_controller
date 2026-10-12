`timescale 1ns/1ps

// The benchmark, in simulation, against the behavioural card.
//
// bench_core is the module that will produce every number we report, so it has to
// be verified like any other RTL and not trusted because it looks like a
// testbench. What it is wired to here is the real ultra_sd_top and the real card
// model: nothing is stubbed, so a pass means the whole measurement path works --
// init, phase scan, write, verified read-back, the characterisation sweep, the
// arithmetic, and the UART.
//
// Sizes are tiny next to the board build (4 blocks instead of 131072), which is
// the point: this checks that the SEQUENCE is right. Whether the numbers are good
// is a question for the card, not the simulator.
//
// The UART output is decoded back into (label, value) pairs and checked. A report
// engine that prints the wrong digits is exactly the kind of bug that would
// otherwise survive into the delivered measurement report.
module tb_bench_flow;
  import ultra_sd_pkg::*;

  // 16 blocks of card storage and a 4-block test region inside it, so nothing
  // wraps the model's modulo-BLOCK_COUNT addressing.
  localparam int CARD_BLOCKS = 16;
  localparam int TEST_BLOCKS = 4;
  localparam int SCAN_BLOCKS = 1;
  localparam int CHAR_BLOCKS = 1;
  localparam int RUNS        = 2;

  // 10 MHz "system clock". The real divisor table ends at /248, which at any
  // simulated clock is slower than the rest of the sequence put together, so the
  // sweep here stops at /32. The absolute rates therefore mean nothing for the
  // board; the arithmetic is checked against what THIS clock implies.
  localparam int SYS_CLK_MHZ = 10;
  localparam int SYS_CLK_HZ  = SYS_CLK_MHZ * 1_000_000;

  localparam logic [5*8-1:0] SIM_DIV_TABLE = {8'd32, 8'd16, 8'd8, 8'd4, 8'd2};

  // One UART bit per 20 clocks: fast enough not to dominate the run, slow enough
  // that the decoder below exercises a real shift rather than a wire.
  localparam int UART_CLKS_PER_BIT = 20;
  localparam real BIT_NS = 100.0 * UART_CLKS_PER_BIT;   // 100 ns per clk at 10 MHz

  // Field order, as bench_core's table emits it.
  localparam int F_SUITE    = 38;
  localparam int F_VERSION  = 0;
  localparam int F_CARD_BLK = 1;
  localparam int F_INIT_MS  = 2;
  localparam int F_CFG_CLK  = 3;
  localparam int F_PHASE    = 4;
  localparam int F_BLOCKS   = 5;
  localparam int F_RD_MIN   = 6;
  localparam int F_RD_MAX   = 7;
  localparam int F_WR_MIN   = 8;
  localparam int F_WR_MAX   = 9;
  localparam int F_RD_EFF   = 10;
  localparam int F_WR_EFF   = 11;
  localparam int F_GAP      = 12;
  localparam int F_MISMATCH = 13;
  localparam int F_RETRY    = 14;
  localparam int F_ERR      = 15;
  localparam int F_STATUS   = 16;
  localparam int F_STAT_DAT = 17;
  localparam int F_SD_CYCLE  = 18;
  localparam int F_FRAM_ERR  = 19;
  localparam int F_FAILFROM = 20;
  localparam int F_INIT_CYC = 21;
  localparam int F_INIT_SD  = 22;
  localparam int F_DBG_STEP = 23;
  localparam int F_DBG_STAT = 24;
  localparam int F_DBG_LAST = 25;
  localparam int F_DBG_ERRS = 26;
  localparam int F_DBG_RESP = 27;
  localparam int F_CAP8_HI  = 28;
  localparam int F_CAP8_LO  = 29;
  localparam int F_CAP55_HI = 30;
  localparam int F_CAP55_LO = 31;
  localparam int F_CAPTX_HI = 32;
  localparam int F_CAPTX_LO = 33;
  localparam int F_RD1_CYC  = 34;
  localparam int F_RD1_TTF  = 35;
  localparam int F_WR1_CYC  = 36;
  localparam int F_WR1_BSY  = 37;
  // Derived, not counted by hand: bench_core prints 38 scalars, then SUITE, then
  // four per-divisor groups. Adding a scalar moves every group, and four
  // hardcoded bases is four places to forget.
  localparam int F_NSCALAR  = 39;   // through SUITE at 38
  localparam int F_NDIV     = 5;
  localparam int F_CH_DIV   = F_NSCALAR;
  localparam int F_CH_RD    = F_CH_DIV + F_NDIV;
  localparam int F_CH_WR    = F_CH_RD  + F_NDIV;
  localparam int F_CH_GAP   = F_CH_WR  + F_NDIV;
  localparam int NFIELDS    = F_NSCALAR + 4 * F_NDIV;

  logic clk = 0;
  logic rst_n = 1;

  always #50 clk = ~clk;      // 10 MHz

  int checks, failures;

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin
      failures++;
      $display("FAIL: %s", message);
    end
  endtask

  // ---- core + bench --------------------------------------------------------
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
  logic       sd_cd = 0;        // card present from the start

  // The init ladder's observation word. tests.mk defines ULTRA_SD_DEBUG_PORT for
  // this test, so the port exists here exactly as it does in the bench build --
  // the diagnostic is exercised in simulation rather than appearing for the
  // first time on hardware.
  logic [63:0] sd_dbg;

  logic       uart_tx;
  logic [3:0] led;
  logic       bench_done, bench_pass;
  // Per-transfer trace, off unless asked for: +bdbg. This is the first thing to
  // turn on when the sequence stalls -- it names the sequencer state, the
  // direction, how many beats were still owed and the error code, which is
  // usually enough to place the fault without opening a waveform.
  integer dbg_xfer;
  always @(posedge clk) begin
    if (!rst_n) dbg_xfer <= 0;
    else if (u_bench.x_done) begin
      if ($test$plusargs("bdbg"))
        $display("DBG xfer=%0d sst=%0d dir=%0d beats=%0d mism=%0d err=%0d cmdcnt=%0d last=%0d cardtx=%0d group=%0d card4=%0d lane=%x line=%0d",
                 dbg_xfer, u_bench.sst_q, u_bench.x_dir, u_bench.beats_left_q,
                 u_bench.mism_q, u_bench.s_err_q[ERR_LSB +: 8],
                 u_card.command_count_o, u_card.last_cmd_o, u_card.dat_tx_state_q,
                 u_card.rd_group_q, u_card.bus_4bit_o,
                 u_sd.bus_wide, u_sd.u_line.cell_q);
      dbg_xfer <= dbg_xfer + 1;
    end
  end

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
    .sd_clk, .sd_cmd, .sd_dat, .sd_cd,
    .dbg (sd_dbg)
  );

  bench_core #(
    .SYS_CLK_MHZ       (SYS_CLK_MHZ),
    .DIV_TARGET        (2),
    .PHASE_MAX         (2),
    .TEST_BLOCKS       (TEST_BLOCKS),
    .SCAN_BLOCKS       (SCAN_BLOCKS),
    .CHAR_BLOCKS       (CHAR_BLOCKS),
    .RUNS              (RUNS),
    .LBA_BASE          (0),
    .UART_CLKS_PER_BIT (UART_CLKS_PER_BIT),
    .DIV_TABLE         (SIM_DIV_TABLE)
  ) u_bench (
    .clk, .rst_n,
    .m_awaddr (awaddr), .m_awvalid (awvalid), .m_awready (awready),
    .m_wdata  (wdata),  .m_wstrb   (wstrb),   .m_wvalid  (wvalid),
    .m_wready (wready), .m_bresp   (bresp),   .m_bvalid  (bvalid),
    .m_bready (bready), .m_araddr  (araddr),  .m_arvalid (arvalid),
    .m_arready(arready),.m_rdata   (rdata),   .m_rresp   (rresp),
    .m_rvalid (rvalid), .m_rready  (rready),
    .rd_tdata_i (rd_tdata),  .rd_tvalid_i (rd_tvalid),
    .rd_tready_o(rd_tready), .rd_tlast_i  (rd_tlast),
    .wr_tdata_o (wr_tdata),  .wr_tvalid_o (wr_tvalid),
    .wr_tready_i(wr_tready), .wr_tlast_o  (wr_tlast),
    .sd_clk_i   (sd_clk),
    .dbg_i      (sd_dbg),
    .uart_tx_o  (uart_tx),    .led_o  (led),
    .done_o     (bench_done), .pass_o (bench_pass)
  );

  // ---- the card ------------------------------------------------------------
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

  // ===========================================================================
  // UART receiver and report decoder
  //
  // Deliberately all bit manipulation, no string class and no associative
  // arrays: the label is accumulated as eight raw bytes in a 64-bit register and
  // the value as a plain integer, so this decoder runs the same under every
  // simulator the repo supports.
  //
  // Line format is fixed by bench_report: eight label characters, " = ", decimal
  // digits, CR, LF.
  // ===========================================================================
  logic [63:0] lab_a [NFIELDS];
  int          val_a [NFIELDS];
  int          lines_seen;

  task automatic uart_rx_byte(output logic [7:0] b);
    @(negedge uart_tx);               // start bit
    #(BIT_NS * 1.5);                  // middle of bit 0
    for (int i = 0; i < 8; i++) begin
      b[i] = uart_tx;
      #(BIT_NS);
    end
  endtask

  initial begin
    logic [7:0]  b;
    logic [63:0] lab;
    int          val;
    int          nchar;
    int          eol;

    lines_seen = 0;
    for (int i = 0; i < NFIELDS; i++) begin
      lab_a[i] = '0;
      val_a[i] = 0;
    end

    forever begin
      lab   = '0;
      val   = 0;
      nchar = 0;

      // One line. No `break`: the repo's simulators do not all support it, and a
      // flag reads the same.
      eol = 0;
      while (eol == 0) begin
        uart_rx_byte(b);
        if (b == 8'h0a) begin
          eol = 1;                                  // LF ends the line
        end else if (b == 8'h0d) begin
          ;                                         // CR, ignore
        end else if (nchar < 8) begin
          lab = {lab[55:0], b};                     // the eight label characters
          nchar++;
        end else if ((b >= 8'h30) && (b <= 8'h39)) begin
          val = val * 10 + int'(b - 8'h30);
        end
      end

      if (lines_seen < NFIELDS) begin
        lab_a[lines_seen] = lab;
        val_a[lines_seen] = val;
      end
      $display("  report[%0d]: %s = %0d", lines_seen, string'(lab), val);
      lines_seen++;
    end
  end

  // A stalled run has one likely cause and several unlikely ones, and saying
  // which is a lot more useful than a timeout message. Checked in order of how
  // far the sequence got.
  task automatic diagnose_stall;
    if (u_bench.sst_q == 0) begin
      $display("FAIL: card never reached STATUS.CARD_READY; init state %0d, err %0d, last CMD%0d",
               u_sd.u_cmd.u_init.init_mode_q, u_sd.init_err_code, u_card.last_cmd_o);
    end else begin
      $display("FAIL: benchmark stalled in sequencer state %0d, transfer state %0d",
               u_bench.sst_q, u_bench.xst_q);
      $display("      dir=%b beats_left=%0d wr(v/r)=%b/%b block_state=%0d line_state=%0d",
               u_bench.x_dir, u_bench.beats_left_q, wr_tvalid, wr_tready,
               u_sd.u_block.step_q, u_sd.u_line.cell_q);
      $display("      block busy=%b fail=%b code=%0d DAT start=%b busy=%b card DAT state=%0d last CMD%0d",
               u_sd.blk_busy, u_sd.blk_fail, u_sd.blk_fail_code,
               u_sd.dat_start, u_sd.rx_busy, u_card.dat_tx_state_q,
               u_card.last_cmd_o);
      $display("      sys_phase=%0d xfer_go=%b block_go_sync=%b init_done=%b LBA=%0d blocks=%0d xfer=%b",
               u_sd.u_sysctl.phase_q, u_sd.xfer_go, u_sd.u_block.go_sync_q,
               u_sd.init_done, u_sd.lba, u_sd.blocks, u_sd.xfer_dir);
    end
  endtask

  // ===========================================================================
  // Stimulus
  // ===========================================================================
  initial begin
    checks = 0; failures = 0;

    // rst_n starts HIGH and is driven low here, so there is a real negedge.
    // Every flop in the design and in the card model is asynchronously reset on
    // that edge; a testbench that initialises rst_n to 0 never produces one, and
    // anything whose clock is parked during reset -- the card model, which runs on
    // sd_clk -- stays at X for the whole simulation.
    #1 rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;

    fork
      begin
        wait (bench_done);
      end
      begin
        #200_000_000;     // 200 ms of simulated time
        diagnose_stall();
        failures++;
      end
    join_any
    disable fork;

    check(bench_done, "benchmark sequence terminated");

    // pass_o is combinational off the same flops that raise done_o, so sampling
    // it in the delta that `wait` resumes in is a race -- the continuous assign
    // is not ordered against the resumed process. One clock edge settles it.
    @(posedge clk);
    check(bench_pass, "benchmark finished clean: no mismatch, no error code");
    check(!card_protocol_err, "card model saw no protocol violation");

    // bench_done rises with the last field handed to the UART, so the final line
    // is still in flight. Twelve character times covers it.
    #(BIT_NS * 10 * 14);

    // ---- the report is complete and in the documented order ----------------
    check(lines_seen == NFIELDS,
          $sformatf("report printed %0d fields, expected %0d", lines_seen, NFIELDS));
    check(lab_a[F_VERSION] == "VERSION ", "field 0 is VERSION");
    check(lab_a[F_RD_MIN]  == "RD_Mbx10", "field 6 is the read rate");
    check(lab_a[F_STATUS]  == "STATUS  ", "field 16 is STATUS");
    check(lab_a[F_CH_WR]   == "CH_WRx10", "the write sweep starts where expected");

    // ---- the printed values are the computed values ------------------------
    // VERSION is magic 0x5344 plus 1.0, read over AXI and printed as decimal:
    // one known 32-bit number proves the read path and the decimal printer
    // agree all the way through.
    check(val_a[F_VERSION] == 32'h5344_0100,
          $sformatf("VERSION printed as %0d (0x%08x)",
                    val_a[F_VERSION], val_a[F_VERSION]));

    check(val_a[F_BLOCKS]  == TEST_BLOCKS, "BLOCKS printed as configured");
    check(val_a[F_CFG_CLK] == 2,           "CFG_CLK printed as the target divisor");

    // Integrity and error code are what pass_o is built from, but they are also
    // the first things a human reads, so check they PRINTED as zero rather than
    // merely being zero inside.
    check(val_a[F_MISMATCH] == 0, "MISMATCH printed as 0");
    // tlast framing (R-IF-6) and AXI SLVERR, folded into one field. Both must be
    // zero for any number on the page to mean anything.
    check(val_a[F_FRAM_ERR] == 0, "FRAM_ERR printed as 0: tlast framing and AXI responses clean");
    // The core's payload-cycle counter against the bench's independent SD edge
    // count. R-IF-11 warns that a counter on the wrong clock doubles every
    // efficiency figure; payload cycles can never exceed elapsed SD cycles, and
    // for a 4-block transfer they should be most of them.
    check(val_a[F_STAT_DAT] > 0, "the core's STAT_DATA counter is not stubbed");
    check(val_a[F_STAT_DAT] <= val_a[F_SD_CYCLE],
          $sformatf("STAT_DATA %0d does not exceed elapsed SD cycles %0d",
                    val_a[F_STAT_DAT], val_a[F_SD_CYCLE]));
    check(val_a[F_ERR]      == 0, "ERR_CODE printed as 0");
    check(val_a[F_RETRY]    == 0, "no retries needed against a clean card");

    // STATUS after the last read: DONE and CARD_READY set, BUSY clear.
    check(val_a[F_STATUS][STATUS_DONE_BIT] &&
          val_a[F_STATUS][STATUS_CARD_RDY_BIT] &&
          !val_a[F_STATUS][STATUS_BUSY_BIT],
          $sformatf("STATUS printed as 0x%02x", val_a[F_STATUS]));

    // 4-bit High Speed is what the ladder negotiates with this model, and the
    // tier depends on it: a benchmark that silently measured a 1-bit bus would
    // be reporting a quarter of the truth and still look clean.
    check(val_a[F_STATUS][STATUS_BUS_WIDTH_LSB +: 2] == 2'd1,
          "STATUS reports the 4-bit bus");

    // The phase scan settled rather than running off the end of its range.
    check(val_a[F_PHASE] <= 2,
          $sformatf("PHASE settled at %0d", val_a[F_PHASE]));

    // ---- the arithmetic ----------------------------------------------------
    // Rather than recompute the divisions here, check the invariants a wrong
    // formula breaks.
    check((val_a[F_RD_MIN] > 0) && (val_a[F_RD_MIN] != 32'hffff_ffff),
          "read rate is a plausible number, not zero and not saturated");
    check(val_a[F_RD_MIN] <= val_a[F_RD_MAX],
          "read rate minimum does not exceed its maximum");
    check((val_a[F_WR_MIN] > 0) && (val_a[F_WR_MIN] != 32'hffff_ffff),
          "write rate is a plausible number");
    check(val_a[F_WR_MIN] <= val_a[F_WR_MAX],
          "write rate minimum does not exceed its maximum");

    // Efficiency is payload over bus capacity, so it cannot exceed 1000 per
    // thousand. A formula that counted system clocks where R-IF-11 wants SD
    // clocks lands at twice the truth and is caught right here.
    check((val_a[F_RD_EFF] > 0) && (val_a[F_RD_EFF] <= 1000),
          $sformatf("read efficiency %0d per thousand is in range", val_a[F_RD_EFF]));
    check((val_a[F_WR_EFF] > 0) && (val_a[F_WR_EFF] <= 1000),
          $sformatf("host write efficiency %0d per thousand is in range",
                    val_a[F_WR_EFF]));

    // ---- the characterisation sweep ---------------------------------------
    // The divisors must come out as configured, and the rate must fall as the
    // clock does: halving the clock cannot make the card faster. This is the
    // cheapest proof that the sweep really rewrote CFG_CLK between points
    // instead of measuring one setting five times.
    for (int i = 0; i < 5; i++)
      check(val_a[F_CH_DIV + i] == int'(SIM_DIV_TABLE[i*8 +: 8]),
            $sformatf("characterisation point %0d reports its divisor", i));

    check(val_a[F_CH_RD + 0] > 0, "characterisation produced a read rate");
    for (int i = 1; i < 5; i++) begin
      check(val_a[F_CH_RD + i] <= val_a[F_CH_RD + i - 1],
            $sformatf("read rate does not rise from divisor %0d to %0d",
                      int'(SIM_DIV_TABLE[(i-1)*8 +: 8]),
                      int'(SIM_DIV_TABLE[i*8 +: 8])));
      check(val_a[F_CH_WR + i] <= val_a[F_CH_WR + i - 1],
            $sformatf("write rate does not rise from divisor %0d to %0d",
                      int'(SIM_DIV_TABLE[(i-1)*8 +: 8]),
                      int'(SIM_DIV_TABLE[i*8 +: 8])));
    end

    if (failures) begin
      $display("tb_bench_flow: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_bench_flow: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("bench_flow.vcd");
      $dumpvars(0, tb_bench_flow);
    end
  end


endmodule

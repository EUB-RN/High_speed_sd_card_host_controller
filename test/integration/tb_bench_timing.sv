`timescale 1ns/1ps

// bench_core's SUITE_TIMING, in simulation against the behavioural card.
//
// The matrix is the one measurement the tier run cannot make. Its phase scan
// stops at the first phase that verifies, so a column that works at exactly one
// phase and a column that works at six look identical to it -- and the
// difference between those two is whether the board still works at the next
// corner. SUITE_TIMING walks every (divisor, phase) cell and reports the mask,
// the widest run in it, and the phase at that run's centre.
//
// WHAT THIS TEST CAN AND CANNOT SAY
//
// The card here is behavioural, so the WIDTH of the window means nothing about
// real silicon -- a model has no setup time to violate. What the simulation can
// prove is everything around the measurement: that the sweep visits every cell
// and terminates, that a cell only counts as working when the read-back really
// verified, that the mask lines up with the cells that passed, and that the
// window and centre-phase arithmetic reported out of it is right. If that
// arithmetic is wrong the board run produces a confident wrong number, which is
// worse than producing none.
//
// The report is read off bench_core's own (rep_idx, rep_label, rep_value) mux
// rather than by decoding the UART: tb_bench_flow already proves the UART and
// the decoder, SUITE_TIMING reuses the same field slots, and sampling the mux
// tests the table itself without a second decoder to keep in step.
module tb_bench_timing;
  import ultra_sd_pkg::*;

  localparam int CARD_BLOCKS = 16;
  localparam int SYS_CLK_MHZ = 10;
  localparam int SYS_CLK_HZ  = SYS_CLK_MHZ * 1_000_000;

  // One block per cell: a wrong sampling phase corrupts the first group it
  // samples, so volume buys nothing and the matrix is 5 x 4 cells.
  localparam int TIMING_BLOCKS     = 1;
  // The regression's matrix is deliberately the smallest one that still walks
  // every axis: two phases, and the fast end of the divisor table.
  //
  // Simulated time is the constraint, and the cost is not the transfers -- it is
  // the core's own NAC timeout (ultra_sd_top: NAC_TIMEOUT_CLK = SD_HZ_HS / 10,
  // counted in cmd_clk). A cell whose phase loses the start bit entirely waits
  // that out, and because the wait is in cmd_clk cycles it grows with the
  // divisor: at divisor 32 one such cell is 1.6 s of simulated time by itself.
  // The board build sweeps the full phase range over the full table, where that
  // same wait is 100 ms of real time; here it would be the whole regression.
  localparam int TIMING_PHASE_MAX  = 1;

  localparam logic [5*8-1:0] SIM_DIV_TABLE = {8'd8, 8'd6, 8'd4, 8'd3, 8'd2};

  localparam int F_NSCALAR = 39;
  localparam int F_NDIV    = 5;
  localparam int F_SUITE   = 38;
  localparam int F_TM_DIV  = F_NSCALAR;
  localparam int F_TM_MASK = F_TM_DIV  + F_NDIV;
  localparam int F_TM_WIN  = F_TM_MASK + F_NDIV;
  localparam int F_TM_BEST = F_TM_WIN  + F_NDIV;
  localparam int NFIELDS   = F_NSCALAR + 4 * F_NDIV;

  // rst_n starts HIGH and is driven low below, so there is a real negedge: the
  // design and the card model reset asynchronously on that edge, and a
  // testbench that initialises it low never produces one.
  logic clk = 0;
  logic rst_n = 1;
  always #50 clk = ~clk;        // 10 MHz

  int checks, failures;
  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin
      failures++;
      $display("FAIL: %s", message);
    end
  endtask

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
  logic       sd_cd = 0;        // ACTIVE LOW: 0 = card present

  logic       uart_tx;
  logic [3:0] led;
  logic       bench_done, bench_pass;

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

  bench_core #(
    .SYS_CLK_MHZ       (SYS_CLK_MHZ),
    .DIV_TARGET        (2),
    .TEST_BLOCKS       (1),
    .SCAN_BLOCKS       (1),
    .CHAR_BLOCKS       (1),
    .RUNS              (1),
    .LBA_BASE          (0),
    .UART_CLKS_PER_BIT (20),
    .DIV_TABLE         (SIM_DIV_TABLE),
    .SUITE             (1),
    .TIMING_BLOCKS     (TIMING_BLOCKS),
    .TIMING_PHASE_MAX  (TIMING_PHASE_MAX)
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
    // Tied off rather than left dangling. This test does not define
    // ULTRA_SD_DEBUG_PORT, so there is no observation word to feed it -- but an
    // unconnected input is X, the DBG_/CAP_ fields derived from it go X, and the
    // report engine's decimal conversion never terminates on an X value. The
    // symptom is a run that reaches S_REPORT and simply stops.
    .dbg_i      (64'h0),
    .uart_tx_o  (uart_tx),    .led_o  (led),
    .done_o     (bench_done), .pass_o (bench_pass)
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

  // ---- the report, sampled off bench_core's own table ----------------------
  // rep_idx is stable for a whole UART line, so rewriting the same slot is
  // harmless and the last write per index is the one that stands.
  logic [63:0] lab_a [NFIELDS];
  int          val_a [NFIELDS];
  logic        seen_a [NFIELDS];

  // Gated on rep_start/bench_done rather than on the sequencer state: the state
  // name is an enum local to bench_core and a hierarchical reference to the
  // literal does not resolve, which silently samples nothing.
  logic reporting;
  always @(posedge clk) begin
    if (!rst_n)                reporting <= 1'b0;
    else if (u_bench.rep_start) reporting <= 1'b1;
    else if (bench_done)        reporting <= 1'b0;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < NFIELDS; i++) seen_a[i] <= 1'b0;
    end else if (reporting) begin
      if (int'(u_bench.rep_idx) < NFIELDS) begin
        lab_a [int'(u_bench.rep_idx)] <= u_bench.rep_label;
        val_a [int'(u_bench.rep_idx)] <= int'(u_bench.rep_value);
        seen_a[int'(u_bench.rep_idx)] <= 1'b1;
      end
    end
  end

  // Independent reference for the two numbers the matrix derives from a mask.
  // Written here from the definition rather than reusing bench_core's function,
  // so the check is a cross-check and not a tautology.
  function automatic int ref_window(input int mask);
    int run, best;
    begin
      run = 0; best = 0;
      for (int i = 0; i < 16; i++) begin
        if ((mask >> i) & 1) begin
          run++;
          if (run > best) best = run;
        end else run = 0;
      end
      ref_window = best;
    end
  endfunction

  int   all_seen, any_mask, m, w, b;

  // Progress trace: +tmdbg prints every sequencer transition with its time, so a
  // run that goes long says WHERE it went long instead of just timing out.
  int   last_sst = -1;
  always @(posedge clk) begin
    if (rst_n && ($test$plusargs("tmdbg")) && (int'(u_bench.sst_q) != last_sst)) begin
      $display("  [%0t] sst %0d -> %0d  div_idx=%0d phase=%0d",
               $time, last_sst, u_bench.sst_q, u_bench.div_idx_q, u_bench.phase_q);
      last_sst = int'(u_bench.sst_q);
    end
  end

  initial begin
    checks = 0; failures = 0;

    #1 rst_n = 0;
    repeat (10) @(posedge clk);
    rst_n = 1;

    fork
      begin
        wait (bench_done);
      end
      begin
        #3_000_000_000;   // 3 s of simulated time: the matrix is 20 cells and
                          // the failing ones pay the core's CRC retries
        $display("FAIL: SUITE_TIMING did not finish, sequencer stuck in state %0d",
                 u_bench.sst_q);
        failures++;
      end
    join_any
    disable fork;

    check(bench_done, "the matrix sweep terminates");
    @(posedge clk);

    // ---- the sweep visited every cell ------------------------------------
    all_seen = 1;
    for (int i = 0; i < NFIELDS; i++) if (!seen_a[i]) all_seen = 0;
    check(all_seen == 1, "every report field is emitted");

    check(val_a[F_SUITE] == 1, "the report says which suite produced it");

    // ---- the per-divisor groups carry the matrix, not the sweep ----------
    check(lab_a[F_TM_DIV]  == "TM_DIV  ", "divisor column is labelled as the matrix");
    check(lab_a[F_TM_MASK] == "TM_MASK ", "mask column is labelled as the matrix");
    check(lab_a[F_TM_WIN]  == "TM_WIN  ", "window column is labelled as the matrix");
    check(lab_a[F_TM_BEST] == "TM_BEST ", "best-phase column is labelled as the matrix");

    $display("");
    $display("  div   mask    window  best");
    any_mask = 0;
    for (int i = 0; i < F_NDIV; i++) begin
      m = val_a[F_TM_MASK + i];
      w = val_a[F_TM_WIN  + i];
      b = val_a[F_TM_BEST + i];
      $display("  %3d   %4h    %4d    %4d", val_a[F_TM_DIV + i], m[15:0], w, b);

      check(val_a[F_TM_DIV + i] == int'(SIM_DIV_TABLE[i*8 +: 8]),
            $sformatf("matrix row %0d reports its divisor", i));

      // No phase above the sweep's limit may be marked: a bit set outside the
      // range the sweep walked would mean the mask is not what it claims.
      check((m >> (TIMING_PHASE_MAX + 1)) == 0,
            $sformatf("row %0d marks no phase the sweep never tried", i));

      check(w == ref_window(m),
            $sformatf("row %0d window is the widest run in its mask", i));

      if (m == 0) begin
        check(b == 255,
              $sformatf("row %0d reports no usable phase rather than naming phase 0", i));
      end else begin
        any_mask = 1;
        check(b < 16, $sformatf("row %0d centre phase is a real phase", i));
        check(((m >> b) & 1) == 1,
              $sformatf("row %0d centre phase is one of the phases that worked", i));
      end
    end
    $display("");

    // If nothing worked anywhere the table above is all zeros and every check
    // on it passes vacuously, which is exactly the shape a broken sweep has.
    check(any_mask == 1, "at least one divisor has a working phase");

    check(!card_protocol_err, "card model saw no protocol violation");

    // MISMATCH is deliberately NOT checked for zero here: in this suite the
    // failing cells are the measurement, and each one contributes the mismatched
    // beats that identified it.

    if (failures) begin
      $display("tb_bench_timing: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_bench_timing: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    #4_000_000_000;
    $fatal(1, "tb_bench_timing timeout");
  end
endmodule

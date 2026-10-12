`timescale 1ns/1ps

// bench_core's SUITE_DEG, in simulation against the behavioural card.
//
// This is the Section 7.4 graceful-degradation procedure as the board runs it,
// run first in simulation so that the hardware attempt is not the first time
// the sequence executes.
//
// THE SEQUENCE, AND WHY IT IS THAT SEQUENCE
//
// CFG_PHY.FORCE_1BIT narrows the HOST only -- system_controller computes
// bus_wide_q as bus_4bit_i & ~force_1bit_i, while the card's width is whatever
// the init ladder's ACMD6 left it at. Setting the bit after initialisation
// therefore desynchronises the two and corrupts every transfer for a reason
// that has nothing to do with degradation. So the suite sets the force bits and
// then re-runs the ladder:
//
//   write CFG_PHY, pulse CTRL.SOFT_RESET, wait for CARD_READY to DROP, wait for
//   it to rise, read STATUS, then do real verified work.
//
// The drop is the part that is easy to leave out and the part that makes the
// test meaningful: polling CARD_READY immediately after the reset reads the
// stale 1 from the previous initialisation and reports success without having
// re-initialised anything.
//
// WHAT IS CHECKED
//
//   - the suite terminates and emits every report field
//   - STATUS reports BUS_WIDTH = 1-bit and SPEED_MODE = Default Speed, which is
//     R-DEG-5: the reported mode is the one actually negotiated, not the one
//     that was asked for
//   - the verified write/read pair in the degraded mode moves every beat with
//     no mismatch, no retry and no error -- a core that describes its own
//     fallback correctly and then cannot move a block has not degraded
//     gracefully
//
// The third fallback of Section 7.4, a reduced SD clock, is not here: the tier
// suite's characterisation sweep already verifies payload at five frequencies
// from the target down to 399 kHz.
module tb_bench_deg;
  import ultra_sd_pkg::*;

  localparam int CARD_BLOCKS = 32;
  localparam int SYS_CLK_MHZ = 10;
  localparam int SYS_CLK_HZ  = SYS_CLK_MHZ * 1_000_000;

  // Four blocks per content case: these ask about shape and content, not volume.
  //
  localparam int EDGE_BLOCKS = 4;

  localparam logic [5*8-1:0] SIM_DIV_TABLE = {8'd8, 8'd6, 8'd4, 8'd3, 8'd2};

  // Group bases in the case table, mirrored from bench_core.
  localparam int EG_SHAPE = 0, EG_PATRN = 5, EG_NEG = 10, EG_BOUND = 15;

  localparam int F_NSCALAR = 39;
  localparam int F_NDIV    = 5;
  localparam int F_SUITE   = 38;
  // Scalar report slots this test reads, mirrored from bench_core's table.
  localparam int F_MISMATCH = 13;
  localparam int F_RETRY    = 14;
  localparam int F_ERRCODE  = 15;
  localparam int F_STATUS   = 16;
  localparam int F_FRAMERR  = 19;
  // Bit positions inside the captured STATUS word.
  localparam int F_RDY_BIT   = 3;
  localparam int F_SPEED_LSB = 4;
  localparam int F_WIDTH_LSB = 6;
  localparam int F_G0 = F_NSCALAR;
  localparam int F_G1 = F_G0 + F_NDIV;
  localparam int F_G2 = F_G1 + F_NDIV;
  localparam int F_G3 = F_G2 + F_NDIV;
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
    .SUITE             (5),
    .EDGE_BLOCKS       (EDGE_BLOCKS),
    .SOAK_ITERS        (1),
    // The size of the one verified pair. Two blocks in 1-bit Default
    // Speed is eight times the duration of the same transfer in 4-bit High
    // Speed, which is enough work for a width or speed mismatch to corrupt
    // rather than to get lucky.
    .SOAK_BLOCKS       (2)
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

  // The packing bench_core uses for a case result.
  function automatic int eg_ok  (input int v); eg_ok   = v & 32'hFF;          endfunction
  function automatic int eg_mism(input int v); eg_mism = (v >> 8)  & 32'hFF;  endfunction
  function automatic int eg_err (input int v); eg_err  = (v >> 16) & 32'hFF;  endfunction

  int   all_seen;

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
        $display("FAIL: SUITE_DEG did not finish, sequencer stuck in state %0d",
                 u_bench.sst_q);
        failures++;
      end
    join_any
    disable fork;

    check(bench_done, "the case sweep terminates");
    @(posedge clk);

    // ---- the sweep visited every cell ------------------------------------
    all_seen = 1;
    for (int i = 0; i < NFIELDS; i++) if (!seen_a[i]) all_seen = 0;
    check(all_seen == 1, "every report field is emitted");

    check(val_a[F_SUITE] == 5, "the report says which suite produced it");

    // ---- the degraded mode, as STATUS reports it --------------------------
    // STATUS is captured by the suite at the moment CARD_READY comes back up
    // after the forced re-initialisation, so this is the mode the ladder
    // actually negotiated under the force bits.
    $display("");
    $display("  STATUS after forced re-init : 0x%08x", val_a[F_STATUS]);
    $display("    BUS_WIDTH  = %0d bit", (val_a[F_STATUS] >> F_WIDTH_LSB) & 1 ? 4 : 1);
    $display("    SPEED_MODE = %0d", (val_a[F_STATUS] >> F_SPEED_LSB) & 3);
    $display("");

    check(((val_a[F_STATUS] >> F_RDY_BIT) & 1) == 1,
          "the card re-initialises under the force bits");
    check((((val_a[F_STATUS] >> F_WIDTH_LSB) & 1) == 0),
          "FORCE_1BIT is honoured and STATUS reports 1-bit");
    check((((val_a[F_STATUS] >> F_SPEED_LSB) & 3) == int'(SPEED_DS)),
          "FORCE_DS is honoured and STATUS reports Default Speed");

    // ---- and it still works in that mode ----------------------------------
    check(val_a[F_MISMATCH] == 0,
          "the verified pair in the degraded mode mismatches no beat");
    check(val_a[F_RETRY] == 0,
          "the degraded pair spends no retry");
    check(val_a[F_ERRCODE] == 0,
          "the degraded pair reports no error");
    check(val_a[F_FRAMERR] == 0,
          "no framing or AXI error in the degraded mode");

    check(!card_protocol_err, "card model saw no protocol violation");

    if (failures) begin
      $display("tb_bench_deg: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_bench_deg: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    #4_000_000_000;
    $fatal(1, "tb_bench_deg timeout");
  end
endmodule

// -----------------------------------------------------------------------------
// bench_core
//   Purpose      : The measurement itself. Everything that is not a pad or a PLL
//                  lives here, so the same module runs on the board and in
//                  simulation against test/common/models/sd_card_model.sv --
//                  which is the only reason to trust it before a bitstream.
//
//   WHAT IT DOES, IN ORDER (Section 12.3, adapted to a self-contained board
//   build -- the acceptance run uses the client's harness, R-MEAS-1)
//
//     1. Wait for STATUS.CARD_READY, timing it. R-FUNC-7 caps this at 500 ms,
//        so the timeout here is deliberately longer: a bench that gives up at
//        500 ms cannot tell you that init took 520.
//     2. SAMPLE_PHASE scan at the target divisor. Try each phase, read a short
//        region, keep the first phase that comes back verified and error-free.
//        This is step zero of 50 MHz bring-up: at divisor 2 there are only two
//        distinct phases and only one of them works (constr/ultra_sd.sdc
//        section 6), and guessing wrong looks exactly like data corruption.
//     3. Precondition: one full-size write whose timing is thrown away, so the
//        measured runs get no benefit from a freshly erased region.
//     4. RUNS x (timed write, then timed verified read-back). The tier is the
//        MINIMUM across runs (R-MEAS-4), so the WORST elapsed count of each
//        direction is what the derived figures are computed from.
//     5. Characterisation sweep: a short run at each divisor in DIV_TABLE, which
//        is R-MEAS-6 and also the fastest way to see whether the design is
//        timing-marginal -- efficiency that is flat across frequency and then
//        falls off a cliff at the top is a sampling problem, not a logic one.
//     6. Print everything over the UART, rates and efficiencies already divided.
//
//   WHAT IT DELIBERATELY DOES NOT DO
//
//     * No buffering of payload anywhere. The write source is an LFSR and the
//       read sink is the same LFSR re-seeded; both run at line rate and neither
//       can absorb a block. Section 12.5's first rule exists because a bench
//       that buffers measures its own FIFO.
//     * No backpressure on the read stream. tready is tied high: this measures
//       the core at full rate, which is what the tier is about. Backpressure is
//       R-IF-7 and belongs in simulation, where tb_block_axis_read covers it.
//
//   Clock domain : clk only. sd_clk_i is an input but is NEVER used as a clock --
//                  it is edge-detected in the clk domain to count SD cycles, the
//                  same way system_controller counts the ramp. R-IF-11 wants SD
//                  cycles, and this gives the bench an elapsed SD count that is
//                  independent of the core's own counters, so the two can be
//                  cross-checked rather than taken on trust.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module bench_core
  import ultra_sd_pkg::*;
#(
  // System clock in whole MHz. Used for the rate arithmetic and the init-time
  // conversion, so it has to match the real clock or every number is wrong.
  parameter int SYS_CLK_MHZ   = 99,

  // Divisor the graded runs use. 2 = fastest = the 50 MHz class.
  parameter int DIV_TARGET    = 2,

  // Highest SAMPLE_PHASE the scan will try. At divisor 2 only 0 and 1 are
  // distinct; a larger number only wastes scan time.
  parameter int PHASE_MAX     = 3,

  // Payload per measured run, in 512-byte blocks. 131072 = 64 MB (R-PERF-4).
  parameter int TEST_BLOCKS   = 131072,

  // Payload for the phase scan and the characterisation sweep. Small on purpose:
  // 64 MB at 400 kHz would take most of a working day.
  parameter int SCAN_BLOCKS   = 64,
  // Big enough that the sweep measures STEADY STATE. At 256 blocks a fixed
  // per-transfer setup cost dominated every point and the curve came out flat
  // at each divisor, which reads exactly like "nothing here scales with the
  // clock" and is in fact "nothing here is the clock yet".
  parameter int CHAR_BLOCKS   = 512,

  parameter int RUNS          = 5,
  parameter int LBA_BASE      = 4096,       // stay off the first couple of MB
  // Gecikme olcumunun okudugu blok: bu kosuda hicbir yazmanin degmedigi bir
  // adres, boylece olculen sey kartin yazma sonrasi toparlanmasi degil.
  parameter int LAT_RD_LBA    = 0,
  parameter int UART_CLKS_PER_BIT = 859,

  // AXI-Stream payload width, must match the core's DATA_W.
  parameter int DATA_W        = 32,

  // Characterisation divisors (R-MEAS-6), packed one byte per point, entry 0 in
  // the low byte. The default is the ~50 / ~25 / ~12 / ~6 MHz and ~400 kHz set
  // for a 99 MHz system clock. It is a parameter rather than a localparam only
  // so that simulation can leave out the 400 kHz point, which costs more
  // simulated time than the whole rest of the sequence put together.
  parameter logic [5*8-1:0] DIV_TABLE = {8'd248, 8'd16, 8'd8, 8'd4, 8'd2}
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- AXI4-Lite master toward ultra_sd_top --------------------------------
  output logic [7:0]  m_awaddr,
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  output logic        m_wvalid,
  input  logic        m_wready,
  input  logic [1:0]  m_bresp,
  input  logic        m_bvalid,
  output logic        m_bready,
  output logic [7:0]  m_araddr,
  output logic        m_arvalid,
  input  logic        m_arready,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,
  input  logic        m_rvalid,
  output logic        m_rready,

  // ---- read payload out of the core ---------------------------------------
  input  logic [DATA_W-1:0] rd_tdata_i,
  input  logic              rd_tvalid_i,
  output logic              rd_tready_o,
  input  logic              rd_tlast_i,

  // ---- write payload into the core ----------------------------------------
  output logic [DATA_W-1:0] wr_tdata_o,
  output logic              wr_tvalid_o,
  input  logic              wr_tready_i,
  output logic              wr_tlast_o,

  // ---- observation --------------------------------------------------------
  input  logic        sd_clk_i,       // counted, never clocked on

  // The core's init-ladder observation word (ultra_sd_cmd dbg_o). Sampled, not
  // acted on: nothing in the measurement depends on it, and it crosses from
  // cmd_clk without a synchroniser because every field in it is a slow state
  // register and a torn sample costs a wrong diagnostic, not a wrong number.
  input  logic [63:0] dbg_i,

  // ---- results ------------------------------------------------------------
  output logic        uart_tx_o,
  output logic [3:0]  led_o,
  output logic        done_o,         // the whole sequence has finished
  output logic        pass_o          // finished clean: no mismatch, no error
);

  localparam int BEATS_PER_BLOCK = BLOCK_BYTES / (DATA_W / 8);   // 128 at 32 bit
  localparam int NDIV            = 5;
  localparam int CALC_BASE       = 8;                 // scalar figures first
  localparam int CALC_STEPS      = CALC_BASE + 2 * NDIV;
  localparam int FIELD_BASE      = 38;
  localparam int NFIELDS         = FIELD_BASE + 4 * NDIV;

  // R-FUNC-7 allows 500 ms for init, so wait 750 before calling the card dead.
  // R-FUNC-7 puts the init budget at 500 ms, and 750 ms used to be this
  // timeout: tight enough that a run could not sit there, loose enough not to
  // fire on a card that merely scraped past. It is deliberately much longer
  // now, because "over budget" and "never finishes" are different bugs and the
  // short timeout printed the same report for both. Judging the 500 ms is the
  // report reader's job -- INIT_ms is right there -- not the timeout's.
  localparam int INIT_TIMEOUT_CYC = 5000 * 1000 * SYS_CLK_MHZ;
  // 10 ms for a single register read. Generous by four orders of magnitude --
  // it is a timeout, not a budget, and the only thing it has to beat is "never".
  localparam int PROBE_TIMEOUT_CYC = 10 * 1000 * SYS_CLK_MHZ;
  // A transfer that has stopped making progress. 2 s covers a 400 kHz
  // characterisation run plus any card-busy stretch the specification permits;
  // past this the transfer is declared dead.
  localparam int XFER_STALL_CYC   = 2 * 1000 * 1000 * SYS_CLK_MHZ;
  // Much shorter: how long the stream may make no progress before the bench
  // pauses it and asks STATUS what is going on. 5 ms is longer than any gap the
  // card can legitimately impose between beats at the slowest divisor, and short
  // enough that a failed transfer is diagnosed rather than waited out.
  localparam int XFER_PROBE_CYC   = 5 * 1000 * SYS_CLK_MHZ;

  // Payload bits of one measured run, and of one characterisation run.
  localparam logic [63:0] TEST_BITS = 64'(TEST_BLOCKS) * 64'(BLOCK_BYTES) * 64'd8;
  localparam logic [63:0] CHAR_BITS = 64'(CHAR_BLOCKS) * 64'(BLOCK_BYTES) * 64'd8;

  // ===========================================================================
  // AXI4-Lite master and its request port
  // ===========================================================================
  logic        rq_valid, rq_we;
  logic [7:0]  rq_addr;
  logic [31:0] rq_wdata;
  logic        rq_busy, rsp_valid;
  logic [31:0] rsp_rdata;
  logic [1:0]  rsp_resp;

  bench_axil_master u_axil (
    .clk, .rst_n,
    .req_valid_i (rq_valid),
    .req_we_i    (rq_we),
    .req_addr_i  (rq_addr),
    .req_wdata_i (rq_wdata),
    .busy_o      (rq_busy),
    .rsp_valid_o (rsp_valid),
    .rsp_rdata_o (rsp_rdata),
    .rsp_resp_o  (rsp_resp),
    .m_awaddr, .m_awvalid, .m_awready, .m_wdata, .m_wstrb, .m_wvalid,
    .m_wready, .m_bresp, .m_bvalid, .m_bready, .m_araddr, .m_arvalid,
    .m_arready, .m_rdata, .m_rresp, .m_rvalid, .m_rready
  );

  // ===========================================================================
  // SD clock edge counter. sd_clk_i is a pad-bound generated clock sampled in
  // the clk domain: two flops for a clean edge, as in system_controller.
  // ===========================================================================
  logic sd_q, sd_d_q, sd_rise;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sd_q   <= 1'b0;
      sd_d_q <= 1'b0;
    end else begin
      sd_q   <= sd_clk_i;
      sd_d_q <= sd_q;
    end
  end
  assign sd_rise = sd_q & ~sd_d_q;

  // Edges seen on the sd_clk pad between reset and CARD_READY. Reported as
  // INIT_SD, and the first number to look at when init times out: the core
  // cannot talk to a card it is not clocking. Zero means no clock ever left
  // the pad -- the 74-cycle ramp in system_controller runs on cmd_clk, so a
  // clock gate that never opens parks the phase FSM in SYS_RAMP with no error
  // to report, which looks exactly like a card that never answered. Nonzero
  // means the clock is running and the silence is the card's.
  logic [31:0] init_sd_q;
  logic        init_sd_run;

  // ===========================================================================
  // Payload generators. Two instances of one LFSR, re-seeded together at the
  // start of every transfer, so the read side knows what the write side sent
  // without storing a byte of it.
  // ===========================================================================
  logic        lfsr_reload;
  logic        wr_step, rd_step;
  logic [31:0] wr_expect, rd_expect;

  bench_lfsr u_lfsr_wr (
    .clk, .rst_n, .reload_i (lfsr_reload), .step_i (wr_step), .data_o (wr_expect)
  );
  bench_lfsr u_lfsr_rd (
    .clk, .rst_n, .reload_i (lfsr_reload), .step_i (rd_step), .data_o (rd_expect)
  );

  // ===========================================================================
  // Transfer engine. The outer sequencer fills in x_dir / x_blocks / x_lba and
  // pulses x_start; this block owns the stream handshakes, the elapsed counters
  // and the integrity check, and raises x_done once the core reports DONE.
  // ===========================================================================
  typedef enum logic [2:0] {
    X_IDLE,
    X_SETUP,      // LBA, BLOCKS, XFER
    X_GO,         // CTRL.START, counters start here
    X_RUN,        // streaming
    X_POLL,       // DONE not seen yet
    X_SNAP,       // ERR and the STAT_* counters read back
    X_FIN
  } xstate_e;

  xstate_e            xst_q;
  logic               x_start;
  logic               x_dir;        // 1 = write
  logic [31:0]        x_lba;
  logic [23:0]        x_blocks;
  logic               x_done;

  logic [31:0]        beats_left_q;
  logic [31:0]        el_sys_q;     // elapsed clk cycles
  logic [31:0]        el_sd_q;      // elapsed SD rising edges
  logic [31:0]        mism_q;       // mismatched beats this transfer
  logic [31:0]        stall_q;      // cycles since the last sign of progress
  // START yazimindan ILK veri biti'ne kadar gecen sure. Throughput bunu
  // gizler: 64 MB'lik bir transferde komut turu amortize olur, tek bloklu bir
  // istekte ise gecikmenin tamami budur.
  logic [31:0]        ttf_q;
  logic               ttf_seen_q;

  logic [31:0]        x_status_q;
  logic [31:0]        s_err_q, s_data_q, s_gap_q, s_busy_q, s_retry_q;

  // Two checks that cost a counter each and catch a whole class of bug the rate
  // figures would happily hide.
  //
  // tlast: R-IF-6 says a read of N blocks produces exactly N*512/(DATA_W/8)
  // beats with tlast on the final one and nowhere else. The bench knows how many
  // beats it expects, so it can hold the core to that -- and a framing error
  // that moves tlast by one beat is invisible in a throughput number but fatal
  // to a real DMA downstream.
  //
  // SLVERR: every register access the bench makes is to a mapped offset, so a
  // non-OKAY response is always a bug (in the decode, or in our own address
  // arithmetic). Silently ignoring it would mean reading 0 from a counter and
  // reporting it as a measurement.
  logic [31:0]        tlast_err_q;
  logic [31:0]        axi_err_q;

  logic [2:0]         step_q;       // sub-step inside a state
  logic               x_stalled_q;

  // Failure bookkeeping. S_FAIL used to be a silent dead end: anything that went
  // wrong -- no card in the slot being the common one -- parked the sequencer
  // forever and not one byte ever left the UART. That is exactly backwards; a
  // failed run is when the report matters most. These two say where it died.
  logic               fail_q;
  logic [4:0]         fail_from_q;


  // ---- stream handshakes --------------------------------------------------
  // tvalid never waits on tready (R-IF-5): it is a function of "is there a beat
  // left to send", and nothing else.
  logic x_streaming;
  assign x_streaming = (xst_q == X_RUN);

  assign wr_tvalid_o = x_streaming &&  x_dir && (beats_left_q != '0);
  assign wr_tdata_o  = wr_expect;
  assign wr_tlast_o  = wr_tvalid_o && (beats_left_q == 32'd1);
  // Do not consume committed FIFO data while the START write response is still
  // returning.  Those beats belong to this request but X_RUN has not loaded
  // its accounting window yet.
  assign rd_tready_o = x_streaming && !x_dir;

  assign wr_step = wr_tvalid_o && wr_tready_i;
  assign rd_step = rd_tvalid_i && rd_tready_o && x_streaming && !x_dir;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      xst_q        <= X_IDLE;
      tlast_err_q  <= '0;
      axi_err_q    <= '0;
      beats_left_q <= '0;
      el_sys_q     <= '0;
      el_sd_q      <= '0;
      mism_q       <= '0;
      stall_q      <= '0;
      step_q       <= '0;
      x_done       <= 1'b0;
      x_stalled_q  <= 1'b0;
      x_status_q   <= '0;
      s_err_q      <= '0;
      s_data_q     <= '0;
      s_gap_q      <= '0;
      s_busy_q     <= '0;
      s_retry_q    <= '0;
      lfsr_reload  <= 1'b0;
    end else begin
      x_done      <= 1'b0;
      lfsr_reload <= 1'b0;

      // Counted across the whole sequence, not per transfer: one bad response
      // anywhere invalidates the run.
      if (rsp_valid && (rsp_resp != 2'b00)) axi_err_q <= axi_err_q + 32'd1;

      // The elapsed counters run from the START write to DONE and nothing else
      // touches them, so what they measure is exactly the transfer. The register
      // reads of X_SNAP are outside the window.
      if ((xst_q == X_RUN) || (xst_q == X_POLL)) begin
        el_sys_q <= el_sys_q + 32'd1;
        if (sd_rise) el_sd_q <= el_sd_q + 32'd1;
      end

      case (xst_q)
        X_IDLE: begin
          if (x_start) begin
            beats_left_q <= 32'(x_blocks) * 32'(BEATS_PER_BLOCK);
            el_sys_q     <= '0;
            el_sd_q      <= '0;
            mism_q       <= '0;
            stall_q      <= '0;
            ttf_q        <= '0;
            ttf_seen_q   <= 1'b0;
            step_q       <= '0;
            x_stalled_q  <= 1'b0;
                  lfsr_reload  <= 1'b1;      // both generators back to the seed
            xst_q        <= X_SETUP;
          end
        end

        // Three register writes, then START. R-IF-3: the core latches LBA,
        // BLOCKS and XFER at the START write, so only "START last" matters.
        X_SETUP: begin
          if (rsp_valid) begin
            if (step_q == 3'd2) xst_q  <= X_GO;
            else                step_q <= step_q + 3'd1;
          end
        end

        X_GO: begin
          if (rsp_valid) begin
            step_q <= '0;
            xst_q  <= X_RUN;
          end
        end

        X_RUN: begin
          if (wr_step || rd_step) begin
            beats_left_q <= beats_left_q - 32'd1;
            stall_q      <= '0;
            if (!ttf_seen_q) begin
              ttf_q      <= el_sys_q;
              ttf_seen_q <= 1'b1;
            end
            if (rd_step && (rd_tdata_i != rd_expect)) mism_q <= mism_q + 32'd1;
            // tlast must be high on exactly the beat the bench knows is last.
            if (rd_step && (rd_tlast_i != (beats_left_q == 32'd1)))
              tlast_err_q <= tlast_err_q + 32'd1;
          end else begin
            stall_q <= stall_q + 32'd1;
          end

          // Two ways out of the stream, and the second one matters.
          //
          // R-IF-6 promises an exact beat count on a transfer that SUCCEEDS, so
          // the beat counter is the normal exit. But a transfer that FAILS stops
          // early and the outstanding beats are never consumed -- so waiting
          // only on the counter turns every mid-transfer error into a hang, and
          // hides the ERR code that would have explained it.
          //
          // So: when the stream stops making progress, stop guessing and go ask
          // STATUS. X_POLL comes back here if the core says it is still working.
          // Pausing the stream to do that is allowed (R-IF-8 requires the core
          // to tolerate a slow producer) and costs nothing when it is stalled
          // anyway. The elapsed counters keep running through X_POLL, so the
          // measurement is unaffected.
          if ((beats_left_q == '0) || (stall_q > 32'(XFER_PROBE_CYC))) begin
            step_q <= '0;
            xst_q  <= X_POLL;
          end else if (stall_q > 32'(XFER_STALL_CYC)) begin
            // Give up on the datapath but still read the registers: the ERR code
            // is the only thing that can explain the hang, and R-IF-9 says the
            // core must have produced one.
            x_stalled_q <= 1'b1;
            xst_q       <= X_POLL;
          end
        end

        // Poll STATUS until DONE. The datapath is finished but the core may still
        // owe a response or a CMD12, and that time belongs in the elapsed count:
        // it is time the host spent waiting for the transfer.
        X_POLL: begin
          if (rsp_valid) begin
            x_status_q <= rsp_rdata;
            if (rsp_rdata[STATUS_DONE_BIT] || x_stalled_q) begin
              step_q <= '0;
              xst_q  <= X_SNAP;
            end else if (beats_left_q != 32'd0) begin
              // Still working and still owes us beats: resume the stream.
              stall_q <= '0;
              xst_q   <= X_RUN;
            end
          end
        end

        X_SNAP: begin
          if (rsp_valid) begin
            case (step_q)
              3'd0: s_err_q   <= rsp_rdata;
              3'd1: s_data_q  <= rsp_rdata;
              3'd2: s_gap_q   <= rsp_rdata;
              3'd3: s_busy_q  <= rsp_rdata;
              default: s_retry_q <= rsp_rdata;
            endcase
            if (step_q == 3'd4) xst_q  <= X_FIN;
            else                step_q <= step_q + 3'd1;
          end
        end

        X_FIN: begin
          x_done <= 1'b1;
          xst_q  <= X_IDLE;
        end

        default: xst_q <= X_IDLE;
      endcase
    end
  end

  // ===========================================================================
  // Outer sequencer
  // ===========================================================================
  typedef enum logic [4:0] {
    S_INIT_WAIT,
    S_READ_INFO,
    S_SET_CFG,
    S_SCAN_WR,
    S_SCAN_RD,
    S_PRECOND,
    S_RUN_WR,
    S_RUN_RD,
    S_CHAR_SET,
    S_CHAR_WR,
    S_CHAR_RD,
    S_CALC,
    S_REPORT,
    S_DONE,
    S_FAIL,
    // Appended, not inserted: every state above keeps the FAILFROM number the
    // README documents. This one runs FIRST, before S_INIT_WAIT, and reads
    // REG_VERSION -- a constant the core answers with regardless of whether a
    // card is in the slot. It exists to split the two failures that otherwise
    // look identical on the report: a core that answers but sees no card
    // (VERSION = 0x53440100, STATUS = 0) from an AXI bus that never answers at
    // all (FAILFROM = 15, and every field below it is a reset value, not a
    // measurement). S_READ_INFO re-reads the same register after init, so on a
    // healthy run this changes nothing that gets printed.
    S_PROBE_VER,
    // Sona eklendi: yukaridaki her durum README'deki FAILFROM numarasini korur.
    // Tek bloklu (CMD24 / CMD17) gecikme olcumu. Precondition'dan SONRA kosar:
    // o noktada saat hedef bolene oturmus ve kart isinmis olur, yani olculen
    // sey gercekten tek bir istegin maliyeti.
    S_LAT_WR,
    S_LAT_RD
  } sstate_e;

  sstate_e     sst_q;
  logic [31:0] init_cyc_q;
  logic [31:0] version_q, cardblk_q, status_q;
  logic [3:0]  phase_q;
  logic [3:0]  run_q;
  logic [2:0]  div_idx_q;
  logic [1:0]  cfg_step_q;
  logic        info_step_q;

  // Is there another SAMPLE_PHASE left to try?
  logic        next_phase;
  assign next_phase = (phase_q != 4'(PHASE_MAX));

  // Worst and best elapsed counts. Worst elapsed = lowest rate = the graded one.
  logic [31:0] rd_cyc_min_q, rd_cyc_max_q, wr_cyc_min_q, wr_cyc_max_q;
  logic [31:0] rd_sd_worst_q, wr_sd_worst_q;
  logic [31:0] rd_gap_worst_q, wr_busy_worst_q, rd_data_worst_q;
  logic [31:0] mism_total_q, retry_q, err_last_q;

  // Tek bloklu (CMD24 / CMD17) islem gecikmeleri. Faz taramasi zaten tam olarak
  // bunu yapiyor; burada sadece zamanlanip saklaniyor. Kabul edilen fazin
  // degerleri kalir, cunku her denemede uzerine yazilir.
  logic [31:0] lat_wr_cyc_q;   // START -> DONE, kart programlama suresi dahil
  logic [31:0] lat_wr_bsy_q;   // bunun icindeki kart-mesgul suresi
  logic [31:0] lat_rd_cyc_q;   // START -> DONE
  logic [31:0] lat_rd_ttf_q;   // START -> ilk AXI-Stream beat
  // Okuma IKI KEZ yapilir ve IKINCISI olculur. Birincisi, onceki tek bloklu
  // yazmanin flash programlamasini yutar: kart o sirada DAT0'i mesgul tutuyor
  // ve S_RD_ARM card_busy temizlenene kadar arm etmiyor, yani ilk okuma 9.15 ms
  // olarak kartin programlama suresini olcuyor, bizimkini degil.
  logic        lat_rd_2nd_q;

  logic [31:0] char_rd_cyc_q [NDIV];
  logic [31:0] char_wr_cyc_q [NDIV];
  // The core's own STAT_GAP for each characterisation read: total SD cycles
  // spent NOT carrying payload during that transfer. Reported raw, per point.
  //
  // This is the field that settles who owns the read gap. Divide it by
  // CHAR_BLOCKS to get cycles per block, then compare the points:
  //   cycles per block roughly CONSTANT across divisors -> the gap is counted
  //     in SD clocks, so it is logic in the clocked path, and halving the
  //     clock halves the wall-clock gap along with everything else;
  //   cycles per block HALVING as the divisor doubles -> the gap is a fixed
  //     amount of TIME the host is waiting for something outside the clock,
  //     which on a read is the card.
  logic [31:0] char_gap_q [NDIV];

  // Derived, filled in during S_CALC.
  logic [31:0] rd_mbps_min_q, rd_mbps_max_q, wr_mbps_min_q, wr_mbps_max_q;
  logic [31:0] rd_eff_q, wr_eff_q, gap_q, init_ms_q;
  logic [31:0] char_rd_mbps_q [NDIV];
  logic [31:0] char_wr_mbps_q [NDIV];

  logic [4:0]  calc_q;
  logic        div_start;
  logic [63:0] div_num;
  logic [31:0] div_den;
  logic        div_busy, div_done;
  logic [31:0] div_quot;

  // Operandlar kaydedilir: div_num/div_den yaklasik 20 case'lik bir mux ve
  // dogrudan bolucunun icindeki "den_i sifir mi" karsilastirmasiyla
  // busy_q/done_q'ya ulasiyordu -- sys_clk kritik yolu buydu. div_start zaten
  // bir cevrim gecikmeli uretildigi icin operandlar start ile ayni kenarda
  // hazir olur.
  logic [63:0] div_num_q;
  logic [31:0] div_den_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_num_q <= '0;
      div_den_q <= 32'd1;
    end else begin
      div_num_q <= div_num;
      div_den_q <= div_den;
    end
  end

  bench_div u_div (
    .clk, .rst_n,
    .start_i (div_start), .num_i (div_num_q), .den_i (div_den_q),
    .busy_o  (div_busy),  .done_o (div_done), .quot_o (div_quot)
  );

  // ---- report engine ------------------------------------------------------
  logic        rep_start;
  logic [7:0]  rep_idx;
  logic [63:0] rep_label;
  logic [31:0] rep_value;
  logic        rep_done;

  bench_report #(
    .UART_CLKS_PER_BIT (UART_CLKS_PER_BIT)
  ) u_rep (
    .clk, .rst_n,
    .start_i   (rep_start),
    .nfields_i (8'(NFIELDS)),
    .idx_o     (rep_idx),
    .label_i   (rep_label),
    .value_i   (rep_value),
    .done_o    (rep_done),
    .uart_tx_o (uart_tx_o)
  );

  // The field table. Labels are exactly 8 characters so the output lines up in a
  // terminal without the report engine needing to pad anything.
  //
  // Everything is an integer, so the two fractional figures are pre-scaled:
  // rates are tenths of a Mbit/s ("x10") and efficiency is parts per thousand
  // ("pm"). 1700 in RD_Mbx10 is 170.0 Mbit/s, which is the Tier 3 line; 850 in
  // RD_EFFpm is the 85% that Tier 3 needs (Table 10-1).
  int unsigned ch_row;
  always_comb begin
    rep_label = "        ";
    rep_value = 32'h0;
    ch_row    = 0;
    case (rep_idx)
      8'd0:  begin rep_label = "VERSION "; rep_value = version_q;            end
      8'd1:  begin rep_label = "CARD_BLK"; rep_value = cardblk_q;            end
      8'd2:  begin rep_label = "INIT_ms "; rep_value = init_ms_q;            end
      8'd3:  begin rep_label = "CFG_CLK "; rep_value = 32'(DIV_TARGET);      end
      8'd4:  begin rep_label = "PHASE   "; rep_value = 32'(phase_q);         end
      8'd5:  begin rep_label = "BLOCKS  "; rep_value = 32'(TEST_BLOCKS);     end
      8'd6:  begin rep_label = "RD_Mbx10"; rep_value = rd_mbps_min_q;        end
      8'd7:  begin rep_label = "RDmaxx10"; rep_value = rd_mbps_max_q;        end
      8'd8:  begin rep_label = "WR_Mbx10"; rep_value = wr_mbps_min_q;        end
      8'd9:  begin rep_label = "WRmaxx10"; rep_value = wr_mbps_max_q;        end
      8'd10: begin rep_label = "RD_EFFpm"; rep_value = rd_eff_q;             end
      8'd11: begin rep_label = "WR_EFFpm"; rep_value = wr_eff_q;             end
      8'd12: begin rep_label = "GAPx1000"; rep_value = gap_q;                end
      8'd13: begin rep_label = "MISMATCH"; rep_value = mism_total_q;         end
      8'd14: begin rep_label = "RETRY   "; rep_value = retry_q;              end
      8'd15: begin rep_label = "ERR_CODE"; rep_value = err_last_q;           end
      8'd16: begin rep_label = "STATUS  "; rep_value = status_q;             end
      // STAT_DATA is the core's own count of payload cycles on DAT[3:0]. Printed
      // next to the bench's independent elapsed SD count so the two can be
      // compared: R-IF-11 warns that a counter on the wrong clock falsifies every
      // efficiency figure, and this is the cross-check that catches it.
      8'd17: begin rep_label = "STAT_DAT"; rep_value = rd_data_worst_q;      end
      8'd18: begin rep_label = "SD_CYCLE"; rep_value = rd_sd_worst_q;        end
      8'd19: begin rep_label = "FRAM_ERR"; rep_value = tlast_err_q + axi_err_q; end
      // Nonzero FAILED means the run aborted and every figure above it is
      // whatever had been measured at that moment, not a result. FAILFROM is the
      // sequencer state it aborted in; INIT_CYC is the raw system-clock count
      // spent waiting for the card, which is the one number that still means
      // something when the abort was the init timeout.
      8'd20: begin rep_label = "FAILFROM"; rep_value = fail_q ? 32'(fail_from_q) : 32'hFFFF_FFFF; end
      8'd21: begin rep_label = "INIT_CYC"; rep_value = init_cyc_q;              end
      8'd22: begin rep_label = "INIT_SD "; rep_value = init_sd_q;                end
      8'd23: begin rep_label = "DBG_STEP"; rep_value = dbg_step_q;               end
      8'd24: begin rep_label = "DBG_STAT"; rep_value = dbg_stat_q;               end
      8'd25: begin rep_label = "DBG_LAST"; rep_value = dbg_last_q;               end
      8'd26: begin rep_label = "DBG_ERRS"; rep_value = dbg_errs_q;               end
      8'd27: begin rep_label = "DBG_RESP"; rep_value = dbg_resp_q;               end
      8'd28: begin rep_label = "CAP8_HI "; rep_value = cap8_q[63:32];            end
      8'd29: begin rep_label = "CAP8_LO "; rep_value = cap8_q[31:0];             end
      8'd30: begin rep_label = "CAP55_HI"; rep_value = cap55_q[63:32];           end
      8'd31: begin rep_label = "CAP55_LO"; rep_value = cap55_q[31:0];            end
      8'd32: begin rep_label = "CAPTX_HI"; rep_value = captx_q[63:32];           end
      8'd33: begin rep_label = "CAPTX_LO"; rep_value = captx_q[31:0];            end
      // ---- tek bloklu islem gecikmeleri, sistem saati cevrimi --------------
      // Throughput bunlari gizler. 64 MB'lik bir istekte komut turu 131072
      // bloga bolunur; tek bloklu bir istekte gecikmenin tamami bu.
      8'd34: begin rep_label = "RD1_CYC "; rep_value = lat_rd_cyc_q;             end
      8'd35: begin rep_label = "RD1_TTF "; rep_value = lat_rd_ttf_q;             end
      8'd36: begin rep_label = "WR1_CYC "; rep_value = lat_wr_cyc_q;             end
      8'd37: begin rep_label = "WR1_BSY "; rep_value = lat_wr_bsy_q;             end
      default: begin
        // Characterisation rows: the divisor, then its read rate, then its write
        // rate, one group after another.
        if (int'(rep_idx) < FIELD_BASE + NDIV) begin
          ch_row    = int'(rep_idx) - FIELD_BASE;
          rep_label = "CH_DIV  ";
          rep_value = 32'(DIV_TABLE[ch_row*8 +: 8]);
        end else if (int'(rep_idx) < FIELD_BASE + 2 * NDIV) begin
          ch_row    = int'(rep_idx) - (FIELD_BASE + NDIV);
          rep_label = "CH_RDx10";
          rep_value = char_rd_mbps_q[ch_row];
        end else if (int'(rep_idx) < FIELD_BASE + 3 * NDIV) begin
          ch_row    = int'(rep_idx) - (FIELD_BASE + 2 * NDIV);
          rep_label = "CH_WRx10";
          rep_value = char_wr_mbps_q[ch_row];
        end else begin
          ch_row    = int'(rep_idx) - (FIELD_BASE + 3 * NDIV);
          rep_label = "CH_GAP  ";
          rep_value = char_gap_q[ch_row];
        end
      end
    endcase
  end

  // ---- AXI request multiplexer -------------------------------------------
  // Every register access the benchmark makes is generated here, from the state
  // the two FSMs are in. One place to look when a register turns out to have
  // been written at the wrong moment, which is the usual bring-up bug.
  //
  // The !rsp_valid term matters: the master drops busy in the same cycle it
  // pulses rsp_valid, and the consuming FSM only advances its step on the next
  // edge. Without it, the cycle after every response would re-issue the access
  // that just completed.
  always_comb begin
    rq_valid = 1'b0;
    rq_we    = 1'b0;
    rq_addr  = REG_STATUS;
    rq_wdata = 32'h0;

    if (!rq_busy && !rsp_valid) begin
      case (xst_q)
        X_SETUP: begin
          rq_valid = 1'b1;
          rq_we    = 1'b1;
          case (step_q)
            3'd0:    begin rq_addr = REG_LBA;    rq_wdata = x_lba;          end
            // BLOCKS and DIR share the packed XFER_CFG register.  Writing the
            // compatibility aliases separately would make the second write
            // clear the first field when all byte strobes are active.
            3'd1: begin
              rq_addr  = REG_XFER_CFG;
              rq_wdata = {x_dir, 7'h00, x_blocks};
            end
            // Counters cleared immediately before START, so STAT_GAP, STAT_BUSY
            // and STAT_DATA describe THIS transfer and nothing else (procedure
            // step 4). Without it they accumulate across runs, and both the
            // efficiency figures and the R-IF-11 cross-check against the bench's
            // own SD-cycle count become meaningless.
            default: begin
              rq_addr  = REG_CTRL;
              rq_wdata = 32'(1 << CTRL_STAT_CLEAR_BIT);
            end
          endcase
        end
        X_GO: begin
          rq_valid = 1'b1;
          rq_we    = 1'b1;
          rq_addr  = REG_CTRL;
          rq_wdata = 32'(1 << CTRL_START_BIT);
        end
        X_POLL: begin
          rq_valid = 1'b1;
          rq_addr  = REG_STATUS;
        end
        X_SNAP: begin
          rq_valid = 1'b1;
          case (step_q)
            3'd0:    rq_addr = REG_ERR;
            3'd1:    rq_addr = REG_STAT_DATA;
            3'd2:    rq_addr = REG_STAT_GAP;
            3'd3:    rq_addr = REG_STAT_BUSY;
            default: rq_addr = REG_STAT_RETRY;
          endcase
        end
        default: begin
          // Outside a transfer the outer FSM owns the bus.
          case (sst_q)
            S_PROBE_VER: begin rq_valid = 1'b1; rq_addr = REG_VERSION; end
            S_INIT_WAIT: begin rq_valid = 1'b1; rq_addr = REG_STATUS; end
            S_READ_INFO: begin
              rq_valid = 1'b1;
              rq_addr  = info_step_q ? REG_CARD_BLK : REG_VERSION;
            end
            S_SET_CFG, S_CHAR_SET: begin
              rq_valid = 1'b1;
              rq_we    = 1'b1;
              case (cfg_step_q)
                2'd0, 2'd1: begin
                  // CFG_CLK and CFG_PHY are fields of the same packed word.
                  rq_addr  = REG_HW_CFG;
                  rq_wdata = {18'h0, 2'h0, phase_q,
                              (sst_q == S_SET_CFG)
                                ? 8'(DIV_TARGET)
                                : DIV_TABLE[int'(div_idx_q)*8 +: 8]};
                end
                // Counters are cleared immediately before each timed transfer,
                // so STAT_GAP and STAT_BUSY describe that transfer alone
                // (procedure step 4).
                default: begin
                  rq_addr  = REG_CTRL;
                  rq_wdata = 32'(1 << CTRL_STAT_CLEAR_BIT);
                end
              endcase
            end
            default: ;
          endcase
        end
      endcase
    end
  end

  // ---- divider operand select --------------------------------------------
  // rate in tenths of Mbit/s   = payload_bits * clk_MHz * 10 / elapsed_cycles
  // efficiency in per-thousand = payload_bits * 1000 / (sd_cycles * 4)
  // mean block gap x1000       = stat_gap * 1000 / (blocks - 1)     [metric L4]
  // init time in ms            = init_cycles / (clk_MHz * 1000)
  //
  // The factor 4 is the four data lines (Figure 12-2).
  // The *4 in the efficiency formula is the four data lines (Figure 12-2), and
  // the subtraction is what removes card-busy time from the write denominator.
  // Named here rather than inlined because a part-select of an expression is not
  // legal Verilog, and because these are the two places a sign error would hide.
  logic [31:0] rd_sd_x4, wr_sd_net, wr_sd_x4;
  assign rd_sd_x4  = rd_sd_worst_q << 2;
  assign wr_sd_net = (wr_sd_worst_q > wr_busy_worst_q)
                       ? (wr_sd_worst_q - wr_busy_worst_q) : 32'd1;
  assign wr_sd_x4  = wr_sd_net << 2;

  logic [2:0]  cx;
  always_comb begin
    div_num = 64'd0;
    div_den = 32'd1;
    cx      = '0;
    case (calc_q)
      5'd0: begin div_num = TEST_BITS * 64'(SYS_CLK_MHZ*10); div_den = rd_cyc_max_q; end
      5'd1: begin div_num = TEST_BITS * 64'(SYS_CLK_MHZ*10); div_den = rd_cyc_min_q; end
      5'd2: begin div_num = TEST_BITS * 64'(SYS_CLK_MHZ*10); div_den = wr_cyc_max_q; end
      5'd3: begin div_num = TEST_BITS * 64'(SYS_CLK_MHZ*10); div_den = wr_cyc_min_q; end
      5'd4: begin div_num = TEST_BITS * 64'd1000; div_den = rd_sd_x4; end
      // host_write_eff excludes card-busy time: the card holding DAT0 low while
      // it programs flash is not our logic wasting cycles.
      5'd5: begin div_num = TEST_BITS * 64'd1000; div_den = wr_sd_x4; end
      5'd6: begin div_num = 64'(rd_gap_worst_q) * 64'd1000;
                  div_den = 32'(TEST_BLOCKS - 1); end
      5'd7: begin div_num = 64'(init_cyc_q);
                  div_den = 32'(SYS_CLK_MHZ * 1000); end
      default: begin
        div_num = CHAR_BITS * 64'(SYS_CLK_MHZ*10);
        if (int'(calc_q) < CALC_BASE + NDIV) begin
          cx      = 3'(int'(calc_q) - CALC_BASE);
          div_den = char_rd_cyc_q[cx];
        end else begin
          cx      = 3'(int'(calc_q) - (CALC_BASE + NDIV));
          div_den = char_wr_cyc_q[cx];
        end
      end
    endcase
  end

  assign init_sd_run = (sst_q == S_PROBE_VER) || (sst_q == S_INIT_WAIT);

  // ---- what the init ladder actually did ---------------------------------
  // INIT_ERR says the ladder gave up; it does not say where, and at the ACMD41
  // step "the card is still busy" and "CMD55 never answered" produce the same
  // code. These three accumulate while init runs and survive into the report:
  //
  //   DBG_STEP  bit N set = ROM step N was entered.  0..9 is the ladder:
  //             0 CMD0, 1 CMD8, 2 ACMD41, 3 CMD2, 4 CMD3, 5 CMD9, 6 CMD7,
  //             7 ACMD51, 8 ACMD6, 9 CMD6. The highest bit set is how far it got.
  //   DBG_STAT  bit N set = command-FSM state N was entered. The one that
  //             matters is C_RETRY (6): set means commands were failing and
  //             being re-sent, clear means every command was answered cleanly
  //             and the card was simply never ready.
  //   DBG_LAST  the whole word, latched the cycle the ladder's step last
  //             changed, so it is the state the ladder was in when it stopped
  //             making progress rather than whatever it idles at afterwards.
  //   DBG_ERRS  bit N set = error code N (Table 5-3) was raised at least once.
  //             DBG_LAST only carries the LAST failure, and on a command the
  //             card answers exactly once -- CMD2 is one -- every attempt after
  //             the first necessarily times out, so the last failure is always
  //             a timeout and says nothing about the first. This mask does:
  //             bit 1 timeout, bit 2 CRC/framing, bit 3 card status.
  //   DBG_RESP  the 32-bit payload of the last short response the ladder got,
  //             latched with DBG_LAST and therefore belonging to the same
  //             moment. At the 2 -> 3 transition this is ACMD41's OCR: bit 31
  //             is the card's power-up-complete flag and bit 30 is CCS. An OCR
  //             with bit 31 clear, or one that is not a plausible voltage mask,
  //             means the ladder advanced on a response it misread.
  logic [31:0] dbg_step_q, dbg_stat_q, dbg_last_q, dbg_errs_q, dbg_resp_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dbg_step_q   <= '0;
      dbg_stat_q   <= '0;
      dbg_last_q   <= '0;
      dbg_errs_q   <= '0;
      dbg_resp_q   <= '0;
    end else if (init_sd_run) begin
      dbg_step_q   <= dbg_step_q | (32'd1 << dbg_i[3:0]);
      dbg_stat_q   <= dbg_stat_q | (32'd1 << dbg_i[7:4]);
      // Sampled every cycle, not at step boundaries. The ladder freezes where
      // it fails and init runs until the bench's own timeout, so the value
      // that survives into the report IS the state it died in -- which the
      // step-boundary snapshot never showed, because the step it dies on is
      // by definition the one it never leaves.
      dbg_last_q <= dbg_i[31:0];
      dbg_resp_q <= dbg_i[63:32];
      // dbg_i[12] is rsp_err_q, dbg_i[20:13] the code that came with it.
      if (dbg_i[12]) dbg_errs_q <= dbg_errs_q | (32'd1 << dbg_i[17:13]);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                        init_sd_q <= '0;
    else if (init_sd_run && sd_rise)   init_sd_q <= init_sd_q + 32'd1;
  end

  // ---- what the CMD line actually carried ---------------------------------
  // Two 64-bit windows off the CMD line (dbg_i[23]), sampled on the sd_clk
  // rising edge --
  // the edge the card's own transmitter sets up for -- starting the moment the
  // command engine begins waiting for a response.
  //
  //   CAP8     the window after CMD8, the first command this board gets an
  //            answer to. Known good, and therefore the control: it shows what
  //            a real response looks like on this bus, at this frequency, with
  //            this capture.
  //   CAP55    the window after the last attempt at the ACMD41 rung, which is
  //            where init stops.
  //
  // One question, two answers. An idle all-ones CAP55 next to a framed CAP8
  // means the card received nothing worth answering and the fault is on the
  // way out. A framed CAP55 means the card answered and the receiver threw it
  // away, and the fault is on the way in.
  //   CAPTX    the window from the moment the engine starts TRANSMITTING at
  //            that rung, i.e. the CMD55 frame as it appears on the wire.
  //            CAP55 says the card did not answer; this says what it was
  //            answering. Read it as: 6 idle ones, then 01, then the 6-bit
  //            index -- 110111 is 55 -- then 32 bits of argument, CRC7, stop.
  logic [63:0] cap_sh_q, cap8_q, cap55_q, captx_q;
  logic [6:0]  cap_cnt_q, captx_cnt_q;
  logic        cap_run_q, cap8_done_q;
  logic        captx_run_q, captx_done_q;
  logic [3:0]  cap_step_q;

  // dbg_i[7:4] is the command engine's state; 3 is C_WAIT_RESP.
  logic cap_trig;
  assign cap_trig = init_sd_run && (dbg_i[7:4] == 4'd3) &&
                    (((dbg_i[3:0] == 4'd1) && !cap8_done_q) ||
                      (dbg_i[3:0] == 4'd2));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cap_sh_q    <= '0;
      cap8_q      <= '0;
      cap55_q     <= '0;
      cap_cnt_q   <= '0;
      cap_run_q   <= 1'b0;
      cap8_done_q <= 1'b0;
      cap_step_q  <= '0;
      captx_q     <= '0;
      captx_cnt_q <= '0;
      captx_run_q <= 1'b0;
      captx_done_q<= 1'b0;
    end else begin
      if (sd_rise) cap_sh_q <= {cap_sh_q[62:0], dbg_i[23]};

      if (!cap_run_q) begin
        if (cap_trig) begin
          cap_run_q  <= 1'b1;
          cap_cnt_q  <= '0;
          cap_step_q <= dbg_i[3:0];
        end
      end else if (sd_rise) begin
        if (cap_cnt_q == 7'd63) begin
          cap_run_q <= 1'b0;
          if (cap_step_q == 4'd1) begin
            cap8_q      <= {cap_sh_q[62:0], dbg_i[23]};
            cap8_done_q <= 1'b1;
          end else begin
            cap55_q <= {cap_sh_q[62:0], dbg_i[23]};
          end
        end else begin
          cap_cnt_q <= cap_cnt_q + 7'd1;
        end
      end

      // The transmit window. State 2 is C_TX; the first time the ACMD41 rung
      // reaches it is the first CMD55 this board ever sends.
      if (!captx_run_q && !captx_done_q) begin
        if (init_sd_run && (dbg_i[7:4] == 4'd2) && (dbg_i[3:0] == 4'd2)) begin
          captx_run_q <= 1'b1;
          captx_cnt_q <= '0;
        end
      end else if (captx_run_q && sd_rise) begin
        if (captx_cnt_q == 7'd63) begin
          captx_run_q  <= 1'b0;
          captx_done_q <= 1'b1;
          captx_q      <= {cap_sh_q[62:0], dbg_i[23]};
        end else begin
          captx_cnt_q <= captx_cnt_q + 7'd1;
        end
      end
    end
  end

  // ---- outer FSM ---------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sst_q           <= S_PROBE_VER;
      init_cyc_q      <= '0;
      version_q       <= '0;
      cardblk_q       <= '0;
      status_q        <= '0;
      phase_q         <= '0;
      run_q           <= '0;
      div_idx_q       <= '0;
      cfg_step_q      <= '0;
      info_step_q     <= 1'b0;
      rd_cyc_min_q    <= 32'hffff_ffff;
      rd_cyc_max_q    <= '0;
      wr_cyc_min_q    <= 32'hffff_ffff;
      wr_cyc_max_q    <= '0;
      rd_sd_worst_q   <= '0;
      wr_sd_worst_q   <= '0;
      rd_gap_worst_q  <= '0;
      wr_busy_worst_q <= '0;
      rd_data_worst_q <= '0;
      mism_total_q    <= '0;
      retry_q         <= '0;
      err_last_q      <= '0;
      calc_q          <= '0;
      x_start         <= 1'b0;
      x_dir           <= 1'b0;
      x_lba           <= '0;
      x_blocks        <= '0;
      lat_wr_cyc_q    <= '0;
      lat_wr_bsy_q    <= '0;
      lat_rd_cyc_q    <= '0;
      lat_rd_ttf_q    <= '0;
      lat_rd_2nd_q    <= 1'b0;
      rep_start       <= 1'b0;
      fail_q          <= 1'b0;
      fail_from_q     <= '0;
      div_start       <= 1'b0;
      rd_mbps_min_q   <= '0;
      rd_mbps_max_q   <= '0;
      wr_mbps_min_q   <= '0;
      wr_mbps_max_q   <= '0;
      rd_eff_q        <= '0;
      wr_eff_q        <= '0;
      gap_q           <= '0;
      init_ms_q       <= '0;
      for (int i = 0; i < NDIV; i++) begin
        char_rd_cyc_q[i]  <= '0;
        char_wr_cyc_q[i]  <= '0;
        char_gap_q[i]     <= '0;
        char_rd_mbps_q[i] <= '0;
        char_wr_mbps_q[i] <= '0;
      end
    end else begin
      x_start   <= 1'b0;
      rep_start <= 1'b0;
      div_start <= 1'b0;

      case (sst_q)
        // ---- 0. is the register bus alive at all? -------------------------
        // One read of a constant register. init_cyc_q is borrowed as the
        // timeout here and zeroed on the way out, so INIT_ms still measures
        // reset release to CARD_READY and nothing else.
        S_PROBE_VER: begin
          init_cyc_q <= init_cyc_q + 32'd1;
          if (rsp_valid) begin
            version_q  <= rsp_rdata;
            init_cyc_q <= '0;
            sst_q      <= S_INIT_WAIT;
          end else if (init_cyc_q > 32'(PROBE_TIMEOUT_CYC)) begin
            fail_from_q <= 5'(sst_q);
            sst_q       <= S_FAIL;
          end
        end

        // ---- 1. wait for the card -----------------------------------------
        S_INIT_WAIT: begin
          init_cyc_q <= init_cyc_q + 32'd1;
          if (rsp_valid) begin
            status_q <= rsp_rdata;
            if (rsp_rdata[STATUS_CARD_RDY_BIT]) begin
              info_step_q <= 1'b0;
              sst_q       <= S_READ_INFO;
            end
          end
          if (init_cyc_q > 32'(INIT_TIMEOUT_CYC)) begin
            fail_from_q <= 5'(sst_q);
            sst_q       <= S_FAIL;
          end
        end

        S_READ_INFO: begin
          if (rsp_valid) begin
            if (!info_step_q) begin
              version_q   <= rsp_rdata;
              info_step_q <= 1'b1;
            end else begin
              cardblk_q  <= rsp_rdata;
              phase_q    <= '0;
              cfg_step_q <= '0;
              sst_q      <= S_SET_CFG;
            end
          end
        end

        // ---- 2. configure, then scan the sampling phase --------------------
        S_SET_CFG: begin
          if (rsp_valid) begin
            if (cfg_step_q == 2'd2) begin
              cfg_step_q <= '0;
              x_dir      <= 1'b1;            // write first: see S_SCAN_WR
              x_lba      <= 32'(LBA_BASE);
              x_blocks   <= 24'(SCAN_BLOCKS);
              x_start    <= 1'b1;
              sst_q      <= S_SCAN_WR;
            end else begin
              cfg_step_q <= cfg_step_q + 2'd1;
            end
          end
        end

        // THE SCAN WRITES BEFORE IT READS, AND IT HAS TO
        //
        // The obvious scan is "read a block and see if it verifies", and it is
        // wrong: nothing has written LFSR data to the card yet, so the first
        // read compares the card's previous contents against the generator and
        // fails at every phase. The scan therefore lays down a short known
        // region first and reads that back.
        //
        // Writing also tests more of the phase than it looks like it does. The
        // card samples OUR data, so the write payload itself does not depend on
        // SAMPLE_PHASE -- but the CRC status token the card sends back on DAT0
        // afterwards does, and we have to sample that correctly to know the
        // block landed. So a bad phase can fail in either direction, and both
        // directions are treated as "try the next phase".
        S_SCAN_WR: begin
          if (x_done) begin
            if (s_err_q[ERR_LSB +: 8] == 8'(ERR_OK)) begin
              x_dir    <= 1'b0;
              x_lba    <= 32'(LBA_BASE);
              x_blocks <= 24'(SCAN_BLOCKS);
              x_start  <= 1'b1;
              sst_q    <= S_SCAN_RD;
            end else if (next_phase) begin
              phase_q    <= phase_q + 4'd1;
              cfg_step_q <= '0;
              sst_q      <= S_SET_CFG;
            end else begin
              err_last_q <= 32'(s_err_q[ERR_LSB +: 8]);
              fail_from_q <= 5'(sst_q);
              sst_q      <= S_FAIL;
            end
          end
        end

        // A phase is good if the read came back with no mismatched beat and no
        // error. Nothing subtler is needed: a wrong sampling phase does not
        // produce slightly wrong data, it produces CRC16 failures and garbage,
        // and both show up here.
        S_SCAN_RD: begin
          if (x_done) begin
            if ((mism_q == '0) &&
                (s_err_q[ERR_LSB +: 8] == 8'(ERR_OK))) begin
              x_dir    <= 1'b1;
              x_lba    <= 32'(LBA_BASE);
              x_blocks <= 24'(TEST_BLOCKS);
              x_start  <= 1'b1;
              sst_q    <= S_PRECOND;
            end else if (next_phase) begin
              phase_q    <= phase_q + 4'd1;
              cfg_step_q <= '0;
              sst_q      <= S_SET_CFG;
            end else begin
              err_last_q <= 32'(s_err_q[ERR_LSB +: 8]);
              fail_from_q <= 5'(sst_q);
              sst_q      <= S_FAIL;
            end
          end
        end

        // ---- 3. preconditioning write, timing discarded -------------------
        S_PRECOND: begin
          if (x_done) begin
            x_dir    <= 1'b1;
            x_lba    <= 32'(LBA_BASE);
            x_blocks <= 24'd1;
            x_start  <= 1'b1;
            sst_q    <= S_LAT_WR;
          end
        end

        // ---- tek bloklu gecikme: bir CMD24, sonra bir CMD17 ---------------
        // OKUMA HEDEFI SOGUK BIR BLOK (LAT_RD_LBA). Iki tuzak var ve ikisi de
        // olculdu: ayni blogu geri okumak kartin flash programlamasini
        // bekletiyor (9.13 ms), 64 MB'lik precondition'in hemen ardindan
        // okumak ise karti tamamen kilitliyor. Ikisi de bizim gecikmemiz
        // degil. Hic dokunmadigimiz bir blok ikisinden de uzak durur; veri
        // LFSR ile tutmaz ama latency durumlari MISMATCH'i beslemiyor.
        S_LAT_WR: begin
          if (x_done) begin
            lat_wr_cyc_q <= el_sys_q;
            lat_wr_bsy_q <= s_busy_q;
            x_dir    <= 1'b0;
            x_lba    <= 32'(LAT_RD_LBA);
            x_blocks <= 24'd1;
            x_start  <= 1'b1;
            sst_q    <= S_LAT_RD;
          end
        end

        S_LAT_RD: if (x_done) begin
          if (!lat_rd_2nd_q) begin
            lat_rd_2nd_q <= 1'b1;        // ilk okuma: kart-mesgul yutulur
            x_dir    <= 1'b0;
            x_lba    <= 32'(LAT_RD_LBA);
            x_blocks <= 24'd1;
            x_start  <= 1'b1;
          end else begin
            lat_rd_cyc_q <= el_sys_q;
            lat_rd_ttf_q <= ttf_q;
            run_q      <= '0;
            cfg_step_q <= '0;
            x_dir      <= 1'b1;
            x_lba      <= 32'(LBA_BASE);
            x_blocks   <= 24'(TEST_BLOCKS);
            x_start    <= 1'b1;
            sst_q      <= S_RUN_WR;
          end
        end

        // ---- 4. the graded runs -------------------------------------------
        S_RUN_WR: begin
          if (x_done) begin
            if (el_sys_q < wr_cyc_min_q) wr_cyc_min_q <= el_sys_q;
            if (el_sys_q > wr_cyc_max_q) begin
              wr_cyc_max_q    <= el_sys_q;
              wr_sd_worst_q   <= el_sd_q;
              wr_busy_worst_q <= s_busy_q;
            end
            retry_q <= s_retry_q;
            if (s_err_q[ERR_LSB +: 8] != 8'(ERR_OK))
              err_last_q <= 32'(s_err_q[ERR_LSB +: 8]);
            x_dir    <= 1'b0;
            x_lba    <= 32'(LBA_BASE);
            x_blocks <= 24'(TEST_BLOCKS);
            x_start  <= 1'b1;
            sst_q    <= S_RUN_RD;
          end
        end

        S_RUN_RD: begin
          if (x_done) begin
            if (el_sys_q < rd_cyc_min_q) rd_cyc_min_q <= el_sys_q;
            if (el_sys_q > rd_cyc_max_q) begin
              rd_cyc_max_q   <= el_sys_q;
              rd_sd_worst_q   <= el_sd_q;
              rd_gap_worst_q  <= s_gap_q;
              rd_data_worst_q <= s_data_q;
            end
            mism_total_q <= mism_total_q + mism_q;
            status_q     <= x_status_q;
            if (s_err_q[ERR_LSB +: 8] != 8'(ERR_OK))
              err_last_q <= 32'(s_err_q[ERR_LSB +: 8]);

            if (run_q == 4'(RUNS - 1)) begin
              div_idx_q  <= '0;
              cfg_step_q <= '0;
              sst_q      <= S_CHAR_SET;
            end else begin
              run_q    <= run_q + 4'd1;
              x_dir    <= 1'b1;
              x_lba    <= 32'(LBA_BASE);
              x_blocks <= 24'(TEST_BLOCKS);
              x_start  <= 1'b1;
              sst_q    <= S_RUN_WR;
            end
          end
        end

        // ---- 5. characterisation sweep (R-MEAS-6) -------------------------
        S_CHAR_SET: begin
          if (rsp_valid) begin
            if (cfg_step_q == 2'd2) begin
              cfg_step_q <= '0;
              x_dir      <= 1'b1;
              x_lba      <= 32'(LBA_BASE);
              x_blocks   <= 24'(CHAR_BLOCKS);
              x_start    <= 1'b1;
              sst_q      <= S_CHAR_WR;
            end else begin
              cfg_step_q <= cfg_step_q + 2'd1;
            end
          end
        end

        S_CHAR_WR: begin
          if (x_done) begin
            char_wr_cyc_q[div_idx_q] <= el_sys_q;
            x_dir    <= 1'b0;
            x_lba    <= 32'(LBA_BASE);
            x_blocks <= 24'(CHAR_BLOCKS);
            x_start  <= 1'b1;
            sst_q    <= S_CHAR_RD;
          end
        end

        S_CHAR_RD: begin
          if (x_done) begin
            char_rd_cyc_q[div_idx_q] <= el_sys_q;
            char_gap_q[div_idx_q]    <= s_gap_q;
            mism_total_q <= mism_total_q + mism_q;
            if (div_idx_q == 3'(NDIV - 1)) begin
              calc_q <= '0;
              sst_q  <= S_CALC;
            end else begin
              div_idx_q  <= div_idx_q + 3'd1;
              cfg_step_q <= '0;
              sst_q      <= S_CHAR_SET;
            end
          end
        end

        // ---- 6. derive the printable figures ------------------------------
        // One divider stepped through the formulas of Figure 12-2. The operands
        // are selected by calc_q in the block above; here we only start it and
        // file the answer.
        S_CALC: begin
          if (!div_busy && !div_done) begin
            div_start <= 1'b1;
          end else if (div_done) begin
            case (calc_q)
              5'd0: rd_mbps_min_q <= div_quot;
              5'd1: rd_mbps_max_q <= div_quot;
              5'd2: wr_mbps_min_q <= div_quot;
              5'd3: wr_mbps_max_q <= div_quot;
              5'd4: rd_eff_q      <= div_quot;
              5'd5: wr_eff_q      <= div_quot;
              5'd6: gap_q         <= div_quot;
              5'd7: init_ms_q     <= div_quot;
              default: begin
                if (int'(calc_q) < CALC_BASE + NDIV)
                  char_rd_mbps_q[int'(calc_q) - CALC_BASE] <= div_quot;
                else
                  char_wr_mbps_q[int'(calc_q) - (CALC_BASE + NDIV)] <= div_quot;
              end
            endcase

            if (calc_q == 5'(CALC_STEPS - 1)) begin
              rep_start <= 1'b1;
              sst_q     <= S_REPORT;
            end else begin
              calc_q <= calc_q + 5'd1;
            end
          end
        end

        S_REPORT: if (rep_done) sst_q <= S_DONE;

        S_DONE: ;

        S_FAIL: begin
          fail_q    <= 1'b1;
          rep_start <= 1'b1;
          sst_q     <= S_REPORT;
        end
        default: begin fail_from_q <= 5'(sst_q); sst_q <= S_FAIL; end
      endcase
    end
  end

  // ===========================================================================
  // Outputs
  // ===========================================================================
  assign done_o = (sst_q == S_DONE);
  assign pass_o = (sst_q == S_DONE) && !fail_q && (mism_total_q == '0) &&
                  (err_last_q[7:0] == 8'(ERR_OK)) &&
                  (tlast_err_q == '0) && (axi_err_q == '0);

  // LEDs: something to read before the UART is wired up. The running state shows
  // as a code so a hang is legible from across the desk, and the pass case is the
  // only thing that blinks -- the same convention pin_check uses.
  logic [23:0] blink_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) blink_q <= '0;
    else        blink_q <= blink_q + 24'd1;
  end

  always_comb begin
    // A pass blinks and nothing else does. A failure holds the top LED and shows
    // the state it died in on the low three, so the abort is readable from the
    // board alone when the UART is not wired up or not believed.
    if (sst_q == S_DONE) led_o = fail_q    ? {1'b1, 3'(fail_from_q)}
                                           : (pass_o ? {blink_q[23], 3'b000}
                                                     : 4'b0111);
    else                 led_o = {1'b0, 3'(sst_q)};
  end

endmodule

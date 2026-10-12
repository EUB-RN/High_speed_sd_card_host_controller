// Command transport only: accept a request, transmit it, collect its response.
// Requests are latched on valid && ready; the producer may change them afterwards.
module ultra_sd_cmd
  import ultra_sd_pkg::*;
#(parameter int NCR_TIMEOUT_CLK=64, NCC_GAP_CLK=8, CMD_RETRIES=3) (
  input logic cmd_clk, rst_n, soft_clr,
  input logic req_valid_i,
  input logic [5:0] req_index_i,
  input logic [31:0] req_arg_i,
  input resp_e req_resp_i,
  input logic req_is_acmd_i,
  input logic [15:0] rca_i,
  output logic req_ready_o,
  output logic rsp_valid_o,
  output logic [RESP_LONG_BITS-1:0] rsp_data_o,
  output logic rsp_crc_ok_o, rsp_err_o,
  output err_e err_o,
  output logic card_ready_o,
  // Successful response has arrived; NCC gap may still be running.
  // DAT consumers must arm now rather than wait for rsp_valid_o.
  output logic rsp_frame_done_o,
  input logic stat_clear_tgl_i,
  output logic [15:0] stat_retry_cmd_o,
  output logic cmd_out_o, cmd_oe_o,
  input logic cmd_in_i
`ifdef ULTRA_SD_DEBUG_PORT
  , output logic [6:0] dbg_o
`endif
);
  logic [5:0] ld_index;
  logic [31:0] ld_arg;
  resp_e ld_resp;
  logic ld_acmd;
  logic [15:0] rca_q;
  localparam int CMD_FRAME_BITS = 48;
  localparam int RESP_SHORT     = RESP_SHORT_BITS;
  localparam int RESP_LONG      = RESP_LONG_BITS;

  localparam int RESP_TAIL_BITS = 8;

  localparam int R2_CRC_SKIP    = 8;

  localparam  RX_CNT_W  = $clog2(RESP_LONG + 1);
  localparam  TIMER_MAX = (NCR_TIMEOUT_CLK > NCC_GAP_CLK) ? NCR_TIMEOUT_CLK : NCC_GAP_CLK;
  localparam  TIMER_W   = $clog2(TIMER_MAX + 1);
  localparam  RTY_W     = $clog2(CMD_RETRIES + 1);

  localparam  R1_READY_FOR_DATA  = 8;
  localparam  R1_OUT_OF_RANGE    = 31;
  localparam  R1_ADDRESS_ERROR   = 30;
  localparam  R1_BLOCK_LEN_ERROR = 29;
  localparam  R1_ERASE_SEQ_ERROR = 28;
  localparam  R1_ERASE_PARAM     = 27;
  localparam  R1_WP_VIOLATION    = 26;
  localparam  R1_LOCK_UNLOCK_FAIL= 24;
  localparam  R1_COM_CRC_ERROR   = 23;
  localparam  R1_ILLEGAL_COMMAND = 22;
  localparam  R1_CARD_ECC_FAILED = 21;
  localparam  R1_CC_ERROR        = 20;
  localparam  R1_ERROR           = 19;
  localparam  R1_CSD_OVERWRITE   = 16;
  localparam  R1_AKE_SEQ_ERROR   = 3;

  localparam  [31:0] R1_ERR_MASK =
      (32'd1 << R1_OUT_OF_RANGE)    | (32'd1 << R1_ADDRESS_ERROR)   |
      (32'd1 << R1_BLOCK_LEN_ERROR) | (32'd1 << R1_ERASE_SEQ_ERROR) |
      (32'd1 << R1_ERASE_PARAM)     | (32'd1 << R1_WP_VIOLATION)    |
      (32'd1 << R1_LOCK_UNLOCK_FAIL)| (32'd1 << R1_COM_CRC_ERROR)   |
      (32'd1 << R1_ILLEGAL_COMMAND) | (32'd1 << R1_CARD_ECC_FAILED) |
      (32'd1 << R1_CC_ERROR)        | (32'd1 << R1_ERROR)           |
      (32'd1 << R1_CSD_OVERWRITE)   | (32'd1 << R1_AKE_SEQ_ERROR);

  localparam int R1_STATUS_LSB = RESP_TAIL_BITS;

  typedef enum logic [3:0] {
    C_IDLE,
    C_LOAD,
    C_TX,
    C_WAIT_RESP,
    C_RX,
    C_EVAL,
    C_RETRY,
    C_GAP,
    C_FIN,
    C_ERROR
  } cmd_state_e;

  cmd_state_e           state_q;

  typedef enum logic [0:0] {
    GAP_TO_IDLE,
    GAP_TO_LOAD
  } gap_next_e;

  gap_next_e            gap_next_q;

  logic                 fail_is_crc_q;

  resp_e                cur_resp_q;

  logic                 send55_q;

  logic                 is_long_resp_q;
  logic                 crc_chk_q;
  logic                 r1_chk_q;

  logic [TIMER_W-1:0]   timer_cnt_q;
  logic [RTY_W-1:0]     retry_q;

  logic [STAT_RTY_W-1:0] stat_rty_cmd_q;
  logic [1:0]            clr_sync_q;
  logic                  clr_q;
  logic                  stat_clear;

  assign stat_clear = clr_sync_q[1] ^ clr_q;

  logic                 card_ready_q;
  logic                 rsp_valid_q;
  logic                 rsp_err_q;
  logic                 rsp_crc_ok_q;
  err_e                 err_q;

  logic                      tx_go_q;
  // Driven by u_tx below, not by this module's own always blocks.
  logic                      tx_done_q;
  logic                      tx_crc_fold;

  logic [5:0]                nxt_index;
  logic [31:0]               nxt_arg;
  logic [CMD_CRC7_BITS-1:0]  tx_crc_data;

  assign nxt_index   = send55_q ? CMD55_APP_CMD    : ld_index;
  assign nxt_arg     = send55_q ? {rca_q, 16'h0000} : ld_arg;

  assign tx_crc_data = {1'b0, 1'b1, nxt_index, nxt_arg};

  logic [CRC7_W-1:0] crc_q;
  logic [CRC7_W-1:0] crc_nxt;

  logic              crc_bit;
  logic              crc_fold_en;

  ultra_sd_crc7 #(
    .IN_WIDTH (1)
  ) u_crc7 (
    .crc_i  (crc_q),
    .data_i (crc_bit),
    .crc_o  (crc_nxt)
  );

  logic [RX_CNT_W-1:0] rx_cnt_q;
  logic [RX_CNT_W-1:0] crc_skip;
  logic                rx_crc_en;

  assign crc_skip  = (cur_resp_q == RESP_R2) ? RX_CNT_W'(R2_CRC_SKIP)
                                             : RX_CNT_W'(0);
  assign rx_crc_en = (rx_cnt_q >= crc_skip) && (!rx_last);

  // Shared capture storage: short responses retain their last 40 bits.
  // R2 retains only CSD_STRUCTURE (2 bits) and C_SIZE (22 bits), packed
  // into [23:0]. All 136 wire bits still pass through the CRC checker.
  logic [39:0] resp_sh_q;
  logic r2_stop_q;
  logic r2_capture;
  assign r2_capture = (rx_cnt_q == RX_CNT_W'(8)) ||
                      (rx_cnt_q == RX_CNT_W'(9)) ||
                      ((rx_cnt_q >= RX_CNT_W'(66)) &&
                       (rx_cnt_q <= RX_CNT_W'(87)));

  logic rx_last;
  logic frame_ok;
  assign rx_last  = is_long_resp_q ? (rx_cnt_q == RX_CNT_W'(RESP_LONG - 1))
                                   : (rx_cnt_q == RX_CNT_W'(RESP_SHORT - 1));
  assign frame_ok = (is_long_resp_q ? r2_stop_q : resp_sh_q[0]) &&
                    ((!crc_chk_q) || (crc_q == CRC7_W'(0)));

  logic rx_shift_en;
  assign rx_shift_en = ((state_q == C_WAIT_RESP) && !cmd_in_i) ||
                       (state_q == C_RX);

  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_sh_q     <= '0;
      r2_stop_q     <= 1'b0;
      rx_cnt_q      <= '0;
    end  else if (rx_shift_en) begin
      if (!is_long_resp_q || r2_capture)
        resp_sh_q <= {resp_sh_q[38:0], cmd_in_i};
      if (is_long_resp_q && rx_last)
        r2_stop_q <= cmd_in_i;

      if (state_q == C_WAIT_RESP) begin
        rx_cnt_q <= RX_CNT_W'(1);
      end else if (rx_last) begin

        rx_cnt_q   <= '0;
      end else begin
        rx_cnt_q <= rx_cnt_q + RX_CNT_W'(1);
      end
    end else if (state_q == C_TX) begin
      rx_cnt_q <= '0;
    end
  end

  logic r1_has_err;
  assign r1_has_err = |(resp_sh_q[R1_STATUS_LSB +: 32] & R1_ERR_MASK);

  ultra_sd_cmd_tx #(
    .CMD_FRAME_BITS (CMD_FRAME_BITS)
  ) u_tx (
    .cmd_clk    (cmd_clk),
    .rst_n      (rst_n),
    .soft_clr   (soft_clr),
    .tx_go_i    (tx_go_q),
    .frame_i    (tx_crc_data),
    .crc_i      (crc_q),
    .cmd_out_o  (cmd_out_o),
    .cmd_oe_o   (cmd_oe_o),
    .tx_done_o  (tx_done_q),
    .crc_fold_o (tx_crc_fold)
  );

  assign crc_bit     = tx_crc_fold ? cmd_out_o : cmd_in_i;

  assign crc_fold_en = tx_crc_fold ||
                       (((state_q == C_WAIT_RESP && !cmd_in_i) ||
                         (state_q == C_RX)) && rx_crc_en);

  // ===========================================================================
  // The command FSM, in three procedural blocks
  //
  // This was a single 179-line always_ff, which R-ARCH-4 rules out at 120.
  // It is split by register group, not by state, so every arm's condition is
  // identical to what it was -- a reorganisation, not a redesign:
  //
  //   1. sequencing -- state_q, gap_next_q, timer_cnt_q
  //   2. datapath   -- the latched request, the frame, and what L3 is told
  //   3. statistics -- STAT_RETRY's command half and its clear handshake
  //
  // Why 1 and 2 and not four tidier blocks: each block that decodes state_q
  // builds its own copy of the ten-way decode, and the placer does not share
  // them. A four-block version of this FSM measured 2503 LUT against 2470 for
  // this one -- 3 over the 2500 budget of R-RES-1. Block 3 is cheap because it
  // tests one state rather than decoding all of them.
  //
  // Only block 1 uses `unique case`: it has an arm for all ten states, so
  // full-coverage checking means something there. Block 2 lists only the
  // states in which its registers move and holds otherwise, which is what its
  // `default: ;` says.
  // ===========================================================================

  // ---- 1. Sequencing: next state, gap destination, the shared timer --------
  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q     <= C_IDLE;
      gap_next_q  <= GAP_TO_IDLE;
      timer_cnt_q <= '0;
    end else begin
      unique case (state_q)

        C_IDLE: if (req_valid_i) state_q <= C_LOAD;

        C_LOAD: state_q <= C_TX;

        C_TX: if (tx_done_q) begin
          if (cur_resp_q == RESP_NONE) begin
            timer_cnt_q <= TIMER_W'(NCC_GAP_CLK);
            gap_next_q  <= GAP_TO_IDLE;
            state_q     <= C_GAP;
          end else begin
            timer_cnt_q <= TIMER_W'(NCR_TIMEOUT_CLK);
            state_q     <= C_WAIT_RESP;
          end
        end

        C_WAIT_RESP: begin
          if (!cmd_in_i) begin
            state_q     <= C_RX;
          end else if (timer_cnt_q == '0) begin
            state_q     <= C_RETRY;
          end else begin
            timer_cnt_q <= timer_cnt_q - TIMER_W'(1);
          end
        end

        C_RX: if (rx_last) state_q <= C_EVAL;

        C_EVAL: begin
          timer_cnt_q <= TIMER_W'(NCC_GAP_CLK);
          if (!frame_ok) begin
            state_q    <= C_RETRY;
          end else begin
            gap_next_q <= send55_q ? GAP_TO_LOAD : GAP_TO_IDLE;
            state_q    <= C_GAP;
          end
        end

        C_RETRY: begin
          timer_cnt_q <= TIMER_W'(NCC_GAP_CLK);
          if (retry_q < RTY_W'(CMD_RETRIES)) begin
            gap_next_q <= GAP_TO_LOAD;
            state_q    <= C_GAP;
          end else begin
            state_q    <= C_ERROR;
          end
        end

        C_GAP: begin
          if (timer_cnt_q != '0) begin
            timer_cnt_q <= timer_cnt_q - TIMER_W'(1);
          end else if (gap_next_q == GAP_TO_LOAD) begin
            state_q <= C_LOAD;
          end else begin
            state_q <= C_FIN;
          end
        end

        C_ERROR: state_q <= C_FIN;

        C_FIN:   state_q <= C_IDLE;

        default: state_q <= C_IDLE;
      endcase

      if (soft_clr) begin
        state_q     <= C_IDLE;
        gap_next_q  <= GAP_TO_IDLE;
        timer_cnt_q <= '0;
      end
    end
  end

  // ---- 2. Datapath: the latched request, the frame, the reported result ----
  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      ld_index <= '0;
      ld_arg <= '0;
      ld_resp <= RESP_NONE;
      ld_acmd <= 1'b0;
      rca_q <= '0;
      fail_is_crc_q  <= 1'b0;
      cur_resp_q     <= RESP_NONE;
      send55_q       <= 1'b0;
      is_long_resp_q <= 1'b0;
      crc_chk_q      <= 1'b1;
      r1_chk_q       <= 1'b0;
      retry_q        <= '0;
      card_ready_q   <= 1'b0;
      rsp_valid_q    <= 1'b0;
      rsp_err_q      <= 1'b0;
      rsp_crc_ok_q   <= 1'b0;
      err_q          <= ERR_OK;
      crc_q          <= CRC7_INIT;
      tx_go_q        <= 1'b0;
    end else begin
      rsp_valid_q <= 1'b0;

      if (crc_fold_en) begin
        crc_q <= crc_nxt;
      end

      case (state_q)

        C_IDLE: if (req_valid_i) begin
          ld_index <= req_index_i;
          ld_arg <= req_arg_i;
          ld_resp <= req_resp_i;
          ld_acmd <= req_is_acmd_i;
          rca_q <= rca_i;
          send55_q      <= req_is_acmd_i;
          retry_q       <= '0;
          rsp_err_q     <= 1'b0;
          rsp_crc_ok_q  <= 1'b0;
          err_q         <= ERR_OK;
          fail_is_crc_q <= 1'b0;
        end

        C_LOAD: begin
          cur_resp_q     <= send55_q ? RESP_R1 : ld_resp;
          is_long_resp_q <= (!send55_q && (ld_resp == RESP_R2));

          crc_chk_q      <= send55_q ? 1'b1 : (ld_resp != RESP_R3);

          r1_chk_q       <= send55_q ? 1'b1
                                     : ((ld_resp == RESP_R1) ||
                                        (ld_resp == RESP_R1B));

          crc_q       <= CRC7_INIT;
          tx_go_q     <= 1'b1;
        end

        C_TX: if (tx_done_q) begin
          tx_go_q   <= 1'b0;
          crc_q     <= CRC7_INIT;
        end

        // A response that never started is a timeout, not a CRC failure.
        C_WAIT_RESP: if (cmd_in_i && (timer_cnt_q == '0)) fail_is_crc_q <= 1'b0;

        C_EVAL: begin
          if (!frame_ok) begin
            fail_is_crc_q <= 1'b1;
          end else if (send55_q) begin
            // CMD55 accepted; the next frame is the ACMD itself.
            send55_q   <= 1'b0;
            retry_q    <= '0;
          end else begin
            rsp_crc_ok_q <= 1'b1;
            if (r1_chk_q) begin
              card_ready_q <= resp_sh_q[R1_STATUS_LSB + R1_READY_FOR_DATA];
              if (r1_has_err) begin
                err_q     <= ERR_CMD_STATUS;
                rsp_err_q <= 1'b1;
              end
            end
          end
        end

        C_RETRY: if (retry_q < RTY_W'(CMD_RETRIES)) begin
          retry_q  <= retry_q + RTY_W'(1);
          send55_q <= ld_acmd;   // a retried ACMD starts from its CMD55
        end

        C_ERROR: begin
          err_q     <= fail_is_crc_q ? ERR_CMD_CRC : ERR_CMD_TIMEOUT;
          rsp_err_q <= 1'b1;
        end

        C_FIN: rsp_valid_q <= 1'b1;

        default: ;
      endcase

      if (soft_clr) begin
        ld_index <= '0;
        ld_arg <= '0;
        ld_resp <= RESP_NONE;
        ld_acmd <= 1'b0;
        rca_q <= '0;
        fail_is_crc_q  <= 1'b0;
        cur_resp_q     <= RESP_NONE;
        send55_q       <= 1'b0;
        is_long_resp_q <= 1'b0;
        crc_chk_q      <= 1'b1;
        r1_chk_q       <= 1'b0;
        retry_q        <= '0;
        card_ready_q   <= 1'b0;
        rsp_valid_q    <= 1'b0;
        rsp_err_q      <= 1'b0;
        rsp_crc_ok_q   <= 1'b0;
        err_q          <= ERR_OK;
        tx_go_q        <= 1'b0;

        // Preserve registers not reset by software clear.
        crc_q <= crc_q;
      end
    end
  end

  // ---- 3. STAT_RETRY, command half, and its clear handshake ---------------
  // One state tested rather than ten decoded; see the note above.
  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      stat_rty_cmd_q <= '0;
      clr_sync_q     <= 2'b00;
      clr_q          <= 1'b0;
    end else begin
      clr_sync_q  <= {clr_sync_q[0],  stat_clear_tgl_i};
      clr_q       <= clr_sync_q[1];

      if (stat_clear) begin
        stat_rty_cmd_q <= '0;
      end else if ((state_q == C_RETRY) && (retry_q < RTY_W'(CMD_RETRIES)) &&
                   !(&stat_rty_cmd_q)) begin
        stat_rty_cmd_q <= stat_rty_cmd_q + STAT_RTY_W'(1);
      end
      // clr_q, clr_sync_q and stat_rty_cmd_q survive soft_clr by design.
    end
  end

  assign req_ready_o = (state_q == C_IDLE);
  assign rsp_valid_o = rsp_valid_q;
  // Preserve field positions at the interface without storing unused R2 bits.
  // CID and other uncaptured R2 fields are intentionally not exposed.
  assign rsp_data_o = is_long_resp_q
      ? {8'b0, resp_sh_q[23:22], 56'b0, resp_sh_q[21:0], 48'b0}
      : {96'b0, resp_sh_q};
  assign rsp_crc_ok_o = rsp_crc_ok_q;
  assign rsp_err_o = rsp_err_q;
  assign err_o = err_q;
  assign card_ready_o = card_ready_q;
  assign rsp_frame_done_o = (state_q == C_EVAL) && frame_ok && !send55_q &&
                            !(r1_chk_q && r1_has_err);
  assign stat_retry_cmd_o = {{(16-STAT_RTY_W){1'b0}}, stat_rty_cmd_q};
`ifdef ULTRA_SD_DEBUG_PORT
  assign dbg_o = {send55_q, 2'(retry_q), state_q};
`endif
endmodule

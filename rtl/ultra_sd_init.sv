// Card initialization policy. All requests use the same transport interface as
// block transfers; no CMD pin, serializer, CRC7 or command retry logic lives here.
module ultra_sd_init
  import ultra_sd_pkg::*;
#(
  parameter int CLK_DIV_INIT=250, CLK_DIV_DS=4, CLK_DIV_HS=2,
  parameter int ACMD41_TIMEOUT_CLK=400_000, DAT_TIMEOUT_CLK=200_000,
  parameter logic [31:0] OCR_REQUEST=32'h40FF_8000,
  parameter bit SCR_CHECK=1'b1, HS_ENABLE=1'b1
) (
  input logic cmd_clk, rst_n, soft_clr,
  input logic card_present_i, ramp_done_i, force_1bit_i, force_ds_i,
  output logic req_valid_o,
  output logic [5:0] req_index_o,
  output logic [31:0] req_arg_o,
  output resp_e req_resp_o,
  output logic req_is_acmd_o,
  input logic req_ready_i, rsp_valid_i, rsp_err_i, rsp_frame_done_i,
  // Only the fields needed for card negotiation are consumed.
  /* verilator lint_off UNUSED */
  input logic [RESP_LONG_BITS-1:0] rsp_data_i,
  /* verilator lint_on UNUSED */
  input err_e cmd_err_i,
  output logic init_busy_o, init_done_o, init_err_o,
  output err_e init_err_code_o,
  // Cancels an outstanding initialization command when the card is removed.
  output logic cancel_o,
  output logic dat_rd_start_o,
  output logic [10:0] dat_rd_bytes_o,
  // Only the fields needed for card negotiation are consumed.
  /* verilator lint_off UNUSED */
  input logic [31:0] dat_rd_data_i,
  /* verilator lint_on UNUSED */
  input logic dat_rd_valid_i, dat_rd_busy_i, dat_rd_crc_ok_i,
  output logic [15:0] rca_o,
  output logic [31:0] card_blk_o,
  output logic bus_4bit_o,
  output speed_e speed_o,
  output logic [CFG_CLK_W-1:0] clk_div_o
`ifdef ULTRA_SD_DEBUG_PORT
  , output logic [5:0] dbg_o
`endif
);
  typedef enum logic [1:0] {INIT_IDLE, INIT_RUN, INIT_DONE, INIT_ERR} init_mode_e;
  typedef enum logic [1:0] {I_SEND, I_WAIT, I_DAT} phase_e;
  init_mode_e init_mode_q;
  phase_e phase_q;
  logic [3:0] step_cnt;
  logic [1:0] pres_sync_q, ramp_sync_q, f1b_sync_q, fds_sync_q;
  logic card_present, ramp_done, force_1bit, force_ds;
  assign card_present = pres_sync_q[1];
  assign ramp_done = ramp_sync_q[1];
  assign force_1bit = f1b_sync_q[1];
  assign force_ds = fds_sync_q[1];
  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      pres_sync_q <= '0; ramp_sync_q <= '0;
      f1b_sync_q <= '0; fds_sync_q <= '0;
    end else begin
      pres_sync_q <= {pres_sync_q[0], card_present_i};
      ramp_sync_q <= {ramp_sync_q[0], ramp_done_i};
      f1b_sync_q <= {f1b_sync_q[0], force_1bit_i};
      fds_sync_q <= {fds_sync_q[0], force_ds_i};
    end
  end
  localparam int WAIT_MAX = (ACMD41_TIMEOUT_CLK > DAT_TIMEOUT_CLK)
                           ? ACMD41_TIMEOUT_CLK : DAT_TIMEOUT_CLK;
  localparam int WAIT_W = $clog2(WAIT_MAX + 1);
  logic [WAIT_W-1:0] wait_cnt_q;
  logic [4:0] word_cnt_q;
  logic [3:0] dat_cap_q;
  logic scr_4bit_q, dat_armed_q, dat_pending_q;
  logic dat_step, dat_len_done;
  assign dat_step = (step_cnt == 4'd7) || (step_cnt == 4'd9);
  assign dat_len_done = (step_cnt == 4'd7) ? (word_cnt_q == 5'd2)
                                          : (word_cnt_q == 5'd16);
  assign req_valid_o = init_busy_o && (phase_q == I_SEND);
  assign init_busy_o = (init_mode_q == INIT_RUN);
  assign init_done_o = (init_mode_q == INIT_DONE);
  assign init_err_o = (init_mode_q == INIT_ERR);
  assign cancel_o = init_busy_o && !card_present;
  assign dat_rd_bytes_o = (step_cnt == 4'd7) ? 11'd8 : 11'd64;
  // Arm as soon as the command response is validated, before the NCC gap ends.
  // Keep the request asserted until the DAT engine takes it, then never re-arm
  // this payload even if its busy signal falls before the command completes.
  assign dat_rd_start_o = init_busy_o && dat_step && !dat_armed_q &&
                         ((phase_q == I_WAIT) || (phase_q == I_DAT)) &&
                         (rsp_frame_done_i || dat_pending_q) && !dat_rd_busy_i;
`ifdef ULTRA_SD_DEBUG_PORT
  assign dbg_o = {init_mode_q, step_cnt};
`endif
  always_comb begin
    req_index_o = CMD0_GO_IDLE_STATE;
    req_arg_o = '0;
    req_resp_o = RESP_NONE;
    req_is_acmd_o = 1'b0;
    case (step_cnt)
      4'd0: begin end
      4'd1: begin req_index_o=CMD8_SEND_IF_COND; req_arg_o=32'h1AA; req_resp_o=RESP_R7; end
      4'd2: begin req_index_o=ACMD41_SD_SEND_OP_COND; req_arg_o=OCR_REQUEST;
                  req_resp_o=RESP_R3; req_is_acmd_o=1'b1; end
      4'd3: begin req_index_o=CMD2_ALL_SEND_CID; req_resp_o=RESP_R2; end
      4'd4: begin req_index_o=CMD3_SEND_RELATIVE_ADDR; req_resp_o=RESP_R6; end
      4'd5: begin req_index_o=CMD9_SEND_CSD; req_arg_o={rca_o,16'b0}; req_resp_o=RESP_R2; end
      4'd6: begin req_index_o=CMD7_SELECT_CARD; req_arg_o={rca_o,16'b0}; req_resp_o=RESP_R1B; end
      4'd7: begin req_index_o=ACMD51_SEND_SCR; req_resp_o=RESP_R1; req_is_acmd_o=1'b1; end
      4'd8: begin req_index_o=ACMD6_SET_BUS_WIDTH; req_arg_o=scr_4bit_q ? 32'd2 : 32'd0;
                  req_resp_o=RESP_R1; req_is_acmd_o=1'b1; end
      4'd9: begin req_index_o=CMD6_SWITCH_FUNC; req_arg_o=32'h80FF_FFF1; req_resp_o=RESP_R1; end
      default: ;
    endcase
  end

  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      init_mode_q <= INIT_IDLE; phase_q <= I_SEND; step_cnt <= '0;
      rca_o <= '0; card_blk_o <= '0;
      speed_o <= SPEED_INIT; bus_4bit_o <= 1'b0; clk_div_o <= CFG_CLK_W'(CLK_DIV_INIT);
      init_err_code_o <= ERR_OK; wait_cnt_q <= '0;
      word_cnt_q <= '0; dat_cap_q <= '0; scr_4bit_q <= 1'b0; dat_armed_q <= 1'b0; dat_pending_q <= 1'b0;
    end else begin
      if (((step_cnt == 4'd2) || (phase_q == I_DAT)) && wait_cnt_q != '0)
        wait_cnt_q <= wait_cnt_q - WAIT_W'(1);
      if ((init_mode_q == INIT_IDLE) && ramp_done) begin
        init_mode_q <= INIT_RUN;
        phase_q <= I_SEND;
      end
      if (init_busy_o && dat_step && rsp_frame_done_i) dat_pending_q <= 1'b1;
      if (dat_pending_q && dat_rd_busy_i) begin
        dat_armed_q <= 1'b1; dat_pending_q <= 1'b0;
      end
      // Capture during the transport's trailing gap as well as I_DAT.
      if (init_busy_o && dat_step && (dat_armed_q || dat_pending_q) && dat_rd_valid_i) begin
        if ((step_cnt == 4'd7) && (word_cnt_q == 5'd0)) dat_cap_q <= dat_rd_data_i[11:8];
        else if ((step_cnt == 4'd9) && (word_cnt_q == 5'd4)) dat_cap_q <= dat_rd_data_i[3:0];
        word_cnt_q <= word_cnt_q + 5'd1;
      end
      if (init_busy_o) case (phase_q)
        I_SEND: if (req_ready_i) begin
          phase_q <= I_WAIT;
          word_cnt_q <= '0; dat_cap_q <= '0; dat_armed_q <= 1'b0; dat_pending_q <= 1'b0;
        end
        I_WAIT: if (rsp_valid_i) begin
          if (rsp_err_i && (step_cnt != 4'd2)) begin
            init_err_code_o <= cmd_err_i; init_mode_q <= INIT_ERR;
          end else begin
            step_cnt <= step_cnt + 4'd1;
            phase_q <= I_SEND;
            case (step_cnt)
              4'd1: if ((rsp_data_i[15:8] == 8'hAA) && (rsp_data_i[19:16] == 4'h1))
                wait_cnt_q <= WAIT_W'(ACMD41_TIMEOUT_CLK);
              else begin init_err_code_o <= ERR_UNSUPPORTED; init_mode_q <= INIT_ERR; end
              // OCR[31] = power-up done, OCR[30] = CCS. CCS = 0 is an SDSC
              // card: byte-addressed, and out of scope per Section 3.2
              // (R-FUNC-5 covers SDHC/SDXC only). Rejecting it here is what
              // lets every layer below address the card in blocks only --
              // there is no byte-address path to carry.
              4'd2: if (!rsp_err_i && rsp_data_i[39]) begin
                if (!rsp_data_i[38]) begin
                  init_err_code_o <= ERR_UNSUPPORTED; init_mode_q <= INIT_ERR;
                end
              end
              else begin
                step_cnt <= 4'd2;
                if (wait_cnt_q == '0) begin init_err_code_o <= ERR_INIT; init_mode_q <= INIT_ERR; end
              end
              4'd4: rca_o <= rsp_data_i[39:24];
              4'd5: if (rsp_data_i[127:126] != 2'b01) begin
                init_err_code_o <= ERR_UNSUPPORTED; init_mode_q <= INIT_ERR;
              end else begin
                card_blk_o <= {(rsp_data_i[69:48] + 22'd1), 10'b0};
                speed_o <= SPEED_DS; clk_div_o <= CFG_CLK_W'(CLK_DIV_DS);
              end
              4'd6: if (!SCR_CHECK) begin scr_4bit_q <= !force_1bit; step_cnt <= 4'd8; end
              4'd7, 4'd9: begin
                step_cnt <= step_cnt; phase_q <= I_DAT;
                wait_cnt_q <= WAIT_W'(DAT_TIMEOUT_CLK);
              end
              4'd8: begin
                bus_4bit_o <= scr_4bit_q;
                if (!HS_ENABLE || force_ds) init_mode_q <= INIT_DONE;
              end
              default: ;
            endcase
          end
        end
        I_DAT: if (wait_cnt_q == '0) begin
          init_err_code_o <= ERR_DAT_TIMEOUT; init_mode_q <= INIT_ERR;
        end else if (!dat_rd_busy_i && dat_len_done) begin
          if (!dat_rd_crc_ok_i) begin init_err_code_o <= ERR_DAT_CRC; init_mode_q <= INIT_ERR; end
          else if (step_cnt == 4'd7) begin
            scr_4bit_q <= dat_cap_q[2] && !force_1bit;
            step_cnt <= 4'd8; phase_q <= I_SEND;
          end else begin
            if (dat_cap_q[3:0] == 4'h1) begin
              clk_div_o <= CFG_CLK_W'(CLK_DIV_HS); speed_o <= SPEED_HS;
            end
            init_mode_q <= INIT_DONE;
          end
        end
        default: phase_q <= I_SEND;
      endcase

      // Final assignments override normal FSM updates on clear/card removal.
      if (soft_clr || !card_present) begin
        init_mode_q <= INIT_IDLE; phase_q <= I_SEND; step_cnt <= '0;
        rca_o <= '0; card_blk_o <= '0;
        speed_o <= SPEED_INIT; bus_4bit_o <= 1'b0; clk_div_o <= CFG_CLK_W'(CLK_DIV_INIT);
        init_err_code_o <= ERR_OK; wait_cnt_q <= '0;
        word_cnt_q <= '0; dat_cap_q <= '0; scr_4bit_q <= 1'b0; dat_armed_q <= 1'b0; dat_pending_q <= 1'b0;
      end
    end
  end
endmodule

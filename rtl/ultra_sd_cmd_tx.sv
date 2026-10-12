// -----------------------------------------------------------------------------
// ultra_sd_cmd_tx -- L2 CMD line serialiser
//
// Purpose      : shift one 48-bit SD command frame out on CMD, splicing the
//                CRC7 that the parent's shared CRC7 register has folded over
//                the 40 payload bits (Physical Layer spec 4.7.2, Figure 4-1).
// Clock domain : cmd_clk, NEGATIVE edge. The launch edge is the falling one so
//                the card samples a settled CMD on its rising edge; see
//                doc/tx_launch_edge.md for the margin analysis.
// Reset        : rst_n asynchronous active-low; soft_clr is a synchronous
//                abort that stops the shifter and releases the pad but leaves
//                the shift registers alone (nothing reads them when idle).
// Implements   : R-FUNC-2 command framing, R-ARCH-3 (split out of
//                ultra_sd_cmd so neither module exceeds 400 lines).
//
// Split out of ultra_sd_cmd rather than redesigned: the body below is the
// serialiser as it was verified, and the interface is the four signals it
// actually needed from its parent. crc_i is read once, at the tx_cnt == 8
// boundary, which is the cycle after the last payload bit has been folded.
// -----------------------------------------------------------------------------
module ultra_sd_cmd_tx
  import ultra_sd_pkg::*;
#(
  parameter int CMD_FRAME_BITS = 48
) (
  input  logic                      cmd_clk,
  input  logic                      rst_n,
  input  logic                      soft_clr,
  // Launch request. Held high by the parent FSM for the whole frame; the
  // parent drops it after observing tx_done_o, which is what re-arms us.
  input  logic                      tx_go_i,
  // The 40 payload bits: start bit, direction bit, index, argument.
  input  logic [CMD_CRC7_BITS-1:0]  frame_i,
  // The parent's shared CRC7 register, sampled at the splice point.
  input  logic [CRC7_W-1:0]         crc_i,
  output logic                      cmd_out_o,
  output logic                      cmd_oe_o,
  output logic                      tx_done_o,
  // High while a PAYLOAD bit is on the pad, so the parent folds CRC over the
  // bits it is actually transmitting and not over the CRC bits themselves.
  output logic                      crc_fold_o
);

  localparam int TX_CNT_W = $clog2(CMD_FRAME_BITS + 1);

  // Separate data paths: command bits never share storage with CRC bits.
  logic [CMD_CRC7_BITS-1:0]  tx_sh_q;
  logic [CRC7_W-2:0]         tx_crc_sh_q;
  logic [TX_CNT_W-1:0]       tx_cnt_q;
  logic                      tx_active_q;

  always_ff @(negedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_sh_q       <= {CMD_CRC7_BITS{1'b1}};
      tx_crc_sh_q   <= '1;
      tx_cnt_q      <= '0;
      tx_active_q   <= 1'b0;
      tx_done_o     <= 1'b0;
      cmd_out_o     <= 1'b1;
      cmd_oe_o      <= 1'b0;
      crc_fold_o    <= 1'b0;
    end else begin
      if (tx_active_q) begin
        tx_cnt_q <= tx_cnt_q - TX_CNT_W'(1);
        if (tx_cnt_q > TX_CNT_W'(8)) begin
          cmd_out_o     <= tx_sh_q[CMD_CRC7_BITS-1];
          tx_sh_q       <= {tx_sh_q[CMD_CRC7_BITS-2:0], 1'b1};
          crc_fold_o    <= 1'b1;
        end else if (tx_cnt_q == TX_CNT_W'(8)) begin

          cmd_out_o           <= crc_i[CRC7_W-1];
          tx_crc_sh_q         <= crc_i[CRC7_W-2:0];
          crc_fold_o          <= 1'b0;
        end else if (tx_cnt_q > TX_CNT_W'(1)) begin

          cmd_out_o           <= tx_crc_sh_q[CRC7_W-2];
          tx_crc_sh_q         <= {tx_crc_sh_q[CRC7_W-3:0], 1'b1};
          crc_fold_o          <= 1'b0;
        end else begin

          cmd_out_o     <= 1'b1;
          crc_fold_o    <= 1'b0;
          tx_active_q   <= 1'b0;
          tx_done_o     <= 1'b1;
        end
      end else if (tx_go_i && !tx_done_o) begin
        cmd_oe_o      <= 1'b1;
        cmd_out_o     <= frame_i[CMD_CRC7_BITS-1];
        tx_sh_q       <= {frame_i[CMD_CRC7_BITS-2:0], 1'b1};
        crc_fold_o    <= 1'b1;
        tx_cnt_q      <= TX_CNT_W'(CMD_FRAME_BITS - 1);
        tx_active_q   <= 1'b1;
      end else begin
        cmd_oe_o      <= 1'b0;
        cmd_out_o     <= 1'b1;
        crc_fold_o    <= 1'b0;
        if (!tx_go_i) begin
          tx_done_o <= 1'b0;
        end
      end

      if (soft_clr) begin
        tx_active_q   <= 1'b0;
        tx_done_o     <= 1'b0;
        cmd_oe_o      <= 1'b0;

        // Preserve registers not reset by software clear.
        cmd_out_o <= cmd_out_o;
        tx_cnt_q <= tx_cnt_q;
        crc_fold_o <= crc_fold_o;
        tx_sh_q <= tx_sh_q;
        tx_crc_sh_q <= tx_crc_sh_q;
      end
    end
  end

endmodule

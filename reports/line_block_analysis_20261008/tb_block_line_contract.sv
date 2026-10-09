`timescale 1ns/1ps
module tb_block_line_contract;
  import ultra_sd_pkg::*;
  logic clk=0, rst_n=0, go=0, dir=0;
  always #5 clk=~clk;
  logic req_valid, rsp_valid=0, response_pending=0;
  logic [5:0] req_index;
  logic dat_start, dat_dir, tx_take, tx_done, tx_ok, tx_tmo;
  logic rx_valid,rx_busy,rx_done,rx_crc,dat_active,card_busy;
  logic [31:0] tx_data,rx_data;
  logic [3:0] dat_out,dat_oe;
  logic wr_ready=0, wr_en,fin,busy,fail;
  err_e fail_code;
  logic early_drive=0;
  always @(posedge clk) begin
    rsp_valid <= response_pending;
    response_pending <= rst_n && req_valid;
    if (rst_n && dat_oe != 0 && !wr_ready) early_drive <= 1;
    if (rst_n && fail) $display("FAIL_EVENT code=%0d rx_busy=%0b",fail_code,rx_busy);
  end
  ultra_sd_block #(.NAC_TIMEOUT_CLK(40),.PROG_TIMEOUT_CLK(2000)) blk (
    .clk(clk),.rst_n(rst_n),.go_i(go),.card_present_i(1'b1),.card_ready_i(1'b1),
    .lba_i(32'd0),.blocks_i(24'd1),.dir_i(dir),.start_range_bad_i(1'b0),
    .start_blocks_zero_i(1'b0),.start_multi_i(1'b0),.block_addr_i(1'b1),.rca_i(16'd1),
    .accept_o(),.busy_o(busy),.fin_o(fin),.fail_o(fail),.fail_code_o(fail_code),
    .stat_clear_tgl_i(1'b0),.stat_gap_o(),.stat_retry_crc_o(),
    .req_valid_o(req_valid),.req_index_o(req_index),.req_arg_o(),.req_resp_o(),
    .req_is_acmd_o(),.req_ready_i(1'b1),.rsp_valid_i(rsp_valid),.rsp_err_i(1'b0),.cmd_err_i(ERR_OK),
    .dat_start_o(dat_start),.dat_dir_o(dat_dir),.tx_data_o(tx_data),.tx_take_i(tx_take),
    .tx_done_i(tx_done),.tx_status_ok_i(tx_ok),.tx_status_tmo_i(tx_tmo),
    .rx_data_i(rx_data),.rx_valid_i(rx_valid),.rx_busy_i(rx_busy),.rx_done_i(rx_done),
    .rx_crc_ok_i(rx_crc),.dat_active_i(dat_active),.card_busy_i(card_busy),
    .rd_data_o(),.rd_en_o(),.rd_commit_o(),.rd_rewind_o(),.rd_room_ok_i(1'b1),
    .wr_data_i(32'h12345678),.wr_last_i(1'b0),.wr_en_o(wr_en),.wr_commit_o(),
    .wr_rewind_o(),.wr_block_ready_i(wr_ready)
  );
  ultra_sd_line line (
    .line_clk(clk),.rst_n(rst_n),.bus_wide_i(1'b1),.stat_clear_tgl_i(1'b0),
    .stat_data_o(),.stat_busy_o(),.dir_i(dat_dir),.start_i(dat_start),.xfer_bytes_i(11'd512),
    .tx_data_i(tx_data),.tx_take_o(tx_take),.tx_busy_o(),.tx_done_o(tx_done),
    .tx_status_o(),.tx_status_ok_o(tx_ok),.tx_status_tmo_o(tx_tmo),
    .rx_data_o(rx_data),.rx_valid_o(rx_valid),.rx_busy_o(rx_busy),.rx_done_o(rx_done),
    .rx_crc_ok_o(rx_crc),.dat_active_o(dat_active),.card_busy_o(card_busy),
    .dat_out_o(dat_out),.dat_oe_o(dat_oe),.dat_in_i(4'hf)
  );
  initial begin
    repeat(3) @(negedge clk);
    rst_n=1;
    repeat(5) @(negedge clk);
    if ($test$plusargs("read_timeout")) begin
      dir=0; go=1;
      wait(fin);
      repeat(10) @(negedge clk);
      $display("READ_TIMEOUT_RESULT fin=%0b block_busy=%0b line_rx_busy=%0b line_state=%0d",fin,busy,rx_busy,line.cell_q);
      if (!rx_busy) $fatal(1,"Expected reproduction did not occur");
      go=0;
      repeat(10) @(negedge clk);
      dir=1;wr_ready=1;go=1;
      repeat(80) @(negedge clk);
      $display("NEXT_WRITE_RESULT block_state=%0d line_state=%0d rx_busy=%0b dat_oe=%b",blk.step_q,line.cell_q,rx_busy,dat_oe);
    end else begin
      dir=1;go=1;
      repeat(100) @(negedge clk);
      $display("EMPTY_WRITE_RESULT early_drive=%0b ready=%0b wr_en=%0b dat_oe=%b block_state=%0d line_state=%0d",early_drive,wr_ready,wr_en,dat_oe,blk.step_q,line.cell_q);
      if (!early_drive) $fatal(1,"Expected reproduction did not occur");
    end
    $finish;
  end
  initial begin #20000; $fatal(1,"Test timeout"); end
endmodule

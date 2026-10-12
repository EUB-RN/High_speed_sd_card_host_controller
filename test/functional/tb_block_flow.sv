`timescale 1ns/1ps

module tb_block_flow;
  import ultra_sd_pkg::*;
  // Yazilim clear'i bu testin konusu degil: sabit 0.
  logic soft_clr = 1'b0;

  logic clk = 0, rst_n, go_i, card_present_i, card_ready_i, dir_i;
  logic [31:0] lba_i, card_blk_i;
  logic [23:0] blocks_i;
  logic [15:0] rca_i;
  logic accept_o, busy_o, fin_o, fail_o;
  // Gap ve CRC-retry artik ham sinyal olarak disari cikmiyor: ikisi de
  // ultra_sd_block'un icinde, olaylarini ureten kollarin yaninda sayiliyor.
  logic stat_clear_tgl_i;
  logic [31:0] stat_gap_o;
  logic [15:0] stat_retry_crc_o;
  err_e fail_code_o, cmd_err_i;
  logic req_valid_o, req_is_acmd_o, req_ready_i, rsp_valid_i, rsp_err_i;
  logic [5:0] req_index_o;
  logic [31:0] req_arg_o;
  resp_e req_resp_o;
  logic dat_start_o, dat_dir_o, tx_take_i, tx_done_i;
  logic tx_status_ok_i, tx_status_tmo_i;
  logic [31:0] tx_data_o, rx_data_i;
  logic rx_valid_i, rx_busy_i, rx_done_i, rx_crc_ok_i;
  logic dat_active_i, card_busy_i;
  logic [31:0] rd_data_o, wr_data_i;
  logic rd_en_o, rd_commit_o, rd_rewind_o, rd_room_ok_i;
  logic wr_last_i, wr_en_o, wr_commit_o, wr_rewind_o, wr_block_ready_i;

  initial stat_clear_tgl_i = 1'b0;
  int checks, failures;
  int rd_words, rd_commits, rd_rewinds;
  int wr_words, wr_commits, wr_rewinds, retry_events;
  logic [31:0] last_cmd_arg;
  logic saw_fail;
  err_e seen_error;

  always #5 clk = ~clk;

  // card_blk_i artik L3'un portu degil: on-denetim L4'te, clk alaninda bir boru
  // hattinda yapiliyor (ultra_sd_top). Test o hesabi burada ayni anlamla
  // uretir, boylece senaryolar card_blk_i'yi eskisi gibi surmeye devam eder.
  logic start_range_bad_i, start_blocks_zero_i, start_multi_i;
  assign start_range_bad_i   = ({1'b0, lba_i} + {1'b0, 32'(blocks_i)}) >
                               {1'b0, card_blk_i};
  assign start_blocks_zero_i = (blocks_i == '0);
  assign start_multi_i       = (blocks_i > 24'd1);

  ultra_sd_block #(
    .CRC_RETRIES(2), .NAC_TIMEOUT_CLK(12), .PROG_TIMEOUT_CLK(12)
  ) dut (.*);

  always @(posedge clk) begin
    if (!rst_n) begin
      rd_words <= 0; rd_commits <= 0; rd_rewinds <= 0;
      wr_words <= 0; wr_commits <= 0; wr_rewinds <= 0;
      retry_events <= 0; saw_fail <= 0; seen_error <= ERR_OK;
    end else begin
      if (rd_en_o) rd_words <= rd_words + 1;
      if (rd_commit_o) rd_commits <= rd_commits + 1;
      if (rd_rewind_o) rd_rewinds <= rd_rewinds + 1;
      if (wr_en_o) wr_words <= wr_words + 1;
      if (wr_commit_o) wr_commits <= wr_commits + 1;
      if (wr_rewind_o) wr_rewinds <= wr_rewinds + 1;
      retry_events <= int'(stat_retry_crc_o);
      if (fail_o) begin saw_fail <= 1; seen_error <= fail_code_o; end
    end
  end

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin failures++; $display("FAIL: %s", message); end
  endtask

  task automatic reset_dut;
    rst_n = 0; go_i = 0; req_ready_i = 0; rsp_valid_i = 0;
    rx_valid_i = 0; rx_done_i = 0; tx_take_i = 0; tx_done_i = 0;
    repeat (3) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
  endtask

  task automatic launch(input logic direction, input logic [23:0] count,
                        input logic [31:0] lba);
    dir_i = direction; blocks_i = count; lba_i = lba;
    @(negedge clk); go_i = 1;
  endtask

  task automatic answer_cmd(input logic [5:0] expected,
                            input logic expected_acmd);
    int timeout;
    timeout = 0;
    while (!req_valid_o && timeout < 30) begin @(posedge clk); #1; timeout++; end
    check(req_valid_o, $sformatf("CMD%0d request timeout", expected));
    last_cmd_arg = req_arg_o;
    check(req_index_o == expected, $sformatf("expected CMD%0d got CMD%0d",
                                             expected, req_index_o));
    check(req_is_acmd_o == expected_acmd, "command ACMD qualifier");
    req_ready_i = 1;
    timeout = 0;
    while (req_valid_o && timeout < 6) begin @(posedge clk); #1; timeout++; end
    check(!req_valid_o, "command request accepted");
    req_ready_i = 0;
    @(negedge clk); rsp_valid_i = 1; rsp_err_i = 0;
    @(posedge clk); #1;
    @(negedge clk); rsp_valid_i = 0;
  endtask

  task automatic send_read_block(input logic crc_ok, input logic [31:0] base);
    int timeout;
    timeout = 0;
    while (!dat_start_o && timeout < 20) begin @(posedge clk); #1; timeout++; end
    check(dat_start_o, "read DAT engine armed");
    for (int i = 0; i < 4; i++) begin
      @(negedge clk); rx_data_i = base + i; rx_valid_i = 1; dat_active_i = 1;
      @(posedge clk); #1;
      check(rd_en_o && rd_data_o == base + i, "read payload forwarded");
      @(negedge clk); rx_valid_i = 0;
    end
    @(negedge clk); dat_active_i = 0; rx_crc_ok_i = crc_ok; rx_done_i = 1;
    @(posedge clk); #1;
    @(negedge clk); rx_done_i = 0; rx_crc_ok_i = 1;
  endtask

  task automatic send_write_block(input logic token_ok, input logic last_flag);
    int timeout;
    timeout = 0;
    while (!dat_start_o && timeout < 20) begin @(posedge clk); #1; timeout++; end
    check(dat_start_o && dat_dir_o, "write DAT engine armed");
    // The line engine acknowledges start before it can request its first word.
    @(posedge clk); #1;
    for (int i = 0; i < 4; i++) begin
      wr_data_i = 32'h90000000 + i;
      wr_last_i = last_flag && (i == 3);
      @(negedge clk); tx_take_i = 1; dat_active_i = 1;
      @(posedge clk); #1; check(wr_en_o, "write payload consumed");
      @(negedge clk); tx_take_i = 0;
    end
    @(negedge clk); dat_active_i = 0; wr_last_i = 0;
    tx_status_ok_i = token_ok; tx_status_tmo_i = 0; tx_done_i = 1;
    @(posedge clk); #1;
    @(negedge clk); tx_done_i = 0; tx_status_ok_i = 1;
  endtask

  task automatic wait_finish(input string message);
    int timeout;
    timeout = 0;
    while (!fin_o && timeout < 40) begin @(posedge clk); #1; timeout++; end
    check(fin_o, message);
  endtask

  initial begin
    checks = 0; failures = 0;
    card_present_i = 1; card_ready_i = 1; card_blk_i = 32'h100000;
    rca_i = 16'h1234; lba_i = 0; blocks_i = 1; dir_i = 0;
    rsp_err_i = 0; cmd_err_i = ERR_OK; rx_data_i = 0; rx_busy_i = 0;
    rx_crc_ok_i = 1; dat_active_i = 0; card_busy_i = 0;
    rd_room_ok_i = 1; wr_data_i = 0; wr_last_i = 0; wr_block_ready_i = 1;
    tx_status_ok_i = 1; tx_status_tmo_i = 0;

    // Single-block read: CMD17, speculative payload, one commit, no CMD12.
    reset_dut(); launch(0, 1, 32'h100);
    answer_cmd(CMD17_READ_SINGLE_BLOCK, 0);
    send_read_block(1, 32'h1000);
    wait_finish("single read finishes");
    check(rd_words == 4 && rd_commits == 1 && rd_rewinds == 0,
          "single read commits exactly one block");
    check(!saw_fail, "single read has no error");

    // Multi-block read: one CMD18, two block commits, then CMD12.
    reset_dut(); launch(0, 2, 32'h200);
    answer_cmd(CMD18_READ_MULTIPLE_BLOCK, 0);
    send_read_block(1, 32'h2000);
    send_read_block(1, 32'h3000);
    answer_cmd(CMD12_STOP_TRANSMISSION, 0);
    wait_finish("multi read finishes after CMD12");
    check(rd_words == 8 && rd_commits == 2, "multi read commits two blocks");

    // Read CRC failure: rewind, CMD13 recovery, reopen CMD17, then succeed.
    reset_dut(); launch(0, 1, 32'h300);
    answer_cmd(CMD17_READ_SINGLE_BLOCK, 0);
    send_read_block(0, 32'h4000);
    answer_cmd(CMD13_SEND_STATUS, 0);
    answer_cmd(CMD17_READ_SINGLE_BLOCK, 0);
    send_read_block(1, 32'h5000);
    wait_finish("CRC retry read finishes");
    check(retry_events == 1 && rd_rewinds == 1 && rd_commits == 1,
          "CRC failure rewinds and retries once");

    // Multi-block write: ACMD23, one CMD25, two accepted blocks, CMD12.
    reset_dut(); launch(1, 2, 32'h400);
    answer_cmd(ACMD23_SET_WR_BLK_ERASE_CNT, 1);
    check(last_cmd_arg == 2, "ACMD23 carries total block count");
    answer_cmd(CMD25_WRITE_MULTIPLE_BLK, 0);
    send_write_block(1, 0);
    send_write_block(1, 1);
    answer_cmd(CMD12_STOP_TRANSMISSION, 0);
    wait_finish("multi write finishes after CMD12");
    check(wr_words == 8 && wr_commits == 2 && wr_rewinds == 0,
          $sformatf("multi write words=%0d commits=%0d rewinds=%0d",
                    wr_words, wr_commits, wr_rewinds));

    // Bounded read-data timeout must recover through CMD13 and report error.
    reset_dut(); launch(0, 1, 32'h500);
    answer_cmd(CMD17_READ_SINGLE_BLOCK, 0);
    repeat (16) @(posedge clk);
    answer_cmd(CMD13_SEND_STATUS, 0);
    wait_finish("read timeout terminates");
    check(saw_fail && seen_error == ERR_DAT_TIMEOUT, "read timeout error code");

    if (failures) begin
      $display("tb_block_flow: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_block_flow: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin #2_000_000; $fatal(1, "tb_block_flow timeout"); end
endmodule

`timescale 1ns/1ps

// Self-test for the SD card VIP.  A real ultra_sd_cmd and ultra_sd_line are
// used as the host, so this checks edge timing and tri-state ownership in
// addition to the model's decoded values.
module tb_sd_card_model;
  import ultra_sd_pkg::*;

  logic sd_clk = 1'b0;
  logic rst_n = 1'b1;
  always #5 sd_clk = ~sd_clk;

  tri cmd;
  tri [3:0] dat;

  logic req_valid;
  logic [5:0] req_index;
  logic [31:0] req_arg;
  resp_e req_resp;
  logic req_is_acmd, req_ready;
  logic rsp_valid, rsp_crc_ok, rsp_err;
  logic [RESP_LONG_BITS-1:0] rsp_data;
  err_e cmd_err;
  logic card_ready;
  logic cmd_out, cmd_oe, cmd_in;
  logic stat_clear_tgl = 1'b0;
  logic [15:0] stat_retry_cmd;

  assign cmd    = cmd_oe ? cmd_out : 1'bz;
  assign cmd_in = cmd;

  ultra_sd_cmd #(
    .NCR_TIMEOUT_CLK(32), .NCC_GAP_CLK(2), .CMD_RETRIES(1)
  ) u_host_cmd (
    .cmd_clk(sd_clk), .rst_n,
    .req_valid_i(req_valid), .req_index_i(req_index), .req_arg_i(req_arg),
    .req_resp_i(req_resp), .req_is_acmd_i(req_is_acmd),
    .req_ready_o(req_ready), .rsp_valid_o(rsp_valid), .rsp_data_o(rsp_data),
    .rsp_crc_ok_o(rsp_crc_ok), .rsp_err_o(rsp_err), .err_o(cmd_err),
    .card_ready_o(card_ready),
    // Merdiven ayni modulde ama bu test onu kullanmiyor: kart yok + rampa yok
    // => I_IDLE'da kalir ve dis istek portu hatta sahiptir.
    .card_present_i(1'b0), .ramp_done_i(1'b0),
    .init_busy_o(), .init_done_o(), .init_err_o(), .init_err_code_o(),
    .dat_rd_start_o(), .dat_rd_bytes_o(),
    .dat_rd_data_i(32'h0), .dat_rd_valid_i(1'b0),
    .dat_rd_busy_i(1'b0), .dat_rd_crc_ok_i(1'b1),
    .rca_o(), .card_blk_o(), .block_addr_o(), .speed_o(),
    .bus_4bit_o(), .clk_div_o(),
    .stat_clear_tgl_i(stat_clear_tgl), .stat_retry_cmd_o(stat_retry_cmd),
    .cmd_out_o(cmd_out), .cmd_oe_o(cmd_oe),
    .cmd_in_i(cmd_in)
  );

  logic line_start, line_dir;
  logic bus_wide;
  logic [31:0] stat_data_cnt, stat_busy_cnt;
  logic [31:0] tx_data, rx_data;
  logic tx_take, tx_busy, tx_done, tx_status_ok, tx_status_tmo;
  logic [2:0] tx_status;
  logic rx_valid, rx_busy, rx_done, rx_crc_ok, dat_active, card_busy;
  logic [3:0] host_dat_out, host_dat_oe;
  logic [3:0] host_dat_in;
  generate
    for (genvar d = 0; d < 4; d++) begin : g_host_dat_driver
      assign dat[d] = host_dat_oe[d] ? host_dat_out[d] : 1'bz;
    end
  endgenerate
  assign host_dat_in = dat;

  ultra_sd_line #(.XFER_BYTES(BLOCK_BYTES), .STAT_WAIT_MAX(12)) u_host_line (
    .line_clk(sd_clk), .rst_n, .bus_wide_i(bus_wide), .dir_i(line_dir),
    .stat_clear_tgl_i(stat_clear_tgl), .stat_data_o(stat_data_cnt),
    .stat_busy_o(stat_busy_cnt),
    .start_i(line_start), .xfer_bytes_i(11'(BLOCK_BYTES)),
    .tx_data_i(tx_data), .tx_take_o(tx_take),
    .tx_busy_o(tx_busy), .tx_done_o(tx_done), .tx_status_o(tx_status),
    .tx_status_ok_o(tx_status_ok), .tx_status_tmo_o(tx_status_tmo),
    .rx_data_o(rx_data), .rx_valid_o(rx_valid), .rx_busy_o(rx_busy),
    .rx_done_o(rx_done), .rx_crc_ok_o(rx_crc_ok), .dat_active_o(dat_active),
    .card_busy_o(card_busy), .dat_out_o(host_dat_out), .dat_oe_o(host_dat_oe),
    .dat_in_i(host_dat_in)
  );

  logic inj_cmd_timeout, inj_cmd_crc, inj_data_crc, inj_write_crc;
  logic inj_busy_stuck;
  logic vip_protocol_error, vip_wide, vip_hs;
  logic [5:0] vip_last_cmd;
  logic [31:0] vip_command_count;

  sd_card_model #(
    .BLOCK_COUNT(64), .NCR_DELAY_CYCLES(2), .NAC_DELAY_CYCLES(4),
    .WRITE_BUSY_CYCLES(4), .ACMD41_BUSY_POLLS(2)
  ) u_card (
    .sd_clk, .rst_n, .card_present_i(1'b1), .sd_cmd(cmd), .sd_dat(dat),
    .inject_cmd_timeout_i(inj_cmd_timeout), .inject_cmd_crc_i(inj_cmd_crc),
    .inject_data_crc_i(inj_data_crc), .inject_write_crc_i(inj_write_crc),
    .inject_busy_stuck_i(inj_busy_stuck),
    .protocol_error_o(vip_protocol_error), .last_cmd_o(vip_last_cmd),
    .command_count_o(vip_command_count), .bus_4bit_o(vip_wide),
    .high_speed_o(vip_hs)
  );

  int checks, failures;
  task automatic check(input logic condition, input string message);
    begin
      checks++;
      if (!condition) begin
        failures++;
        $display("  FAIL  %s", message);
      end
    end
  endtask

  task automatic issue(input logic [5:0] index,
                       input logic [31:0] argument,
                       input resp_e response,
                       input logic is_acmd);
    integer timeout;
    begin
      $display("  issue CMD%0d%s", index, is_acmd ? " (ACMD)" : "");
      wait (req_ready);
      @(negedge sd_clk);
      req_index   = index;
      req_arg     = argument;
      req_resp    = response;
      req_is_acmd = is_acmd;
      req_valid   = 1'b1;
      @(posedge sd_clk);
      @(negedge sd_clk);
      req_valid = 1'b0;
      timeout = 0;
      while (rsp_valid && timeout < 20) begin
        @(posedge sd_clk); timeout++;
      end
      while (!rsp_valid && timeout < 500) begin
        @(posedge sd_clk); timeout++;
      end
      check(rsp_valid, $sformatf("CMD%0d response completed", index));
      $display("  done  CMD%0d rsp_err=%b", index, rsp_err);
    end
  endtask

  logic [31:0] rx_words [0:127];
  integer rx_count;
  always @(posedge sd_clk) if (rx_valid) begin
    rx_words[rx_count] <= rx_data;
    rx_count <= rx_count + 1;
  end

  logic [31:0] tx_words [0:127];
  integer tx_index;
  assign tx_data = tx_words[(tx_index < 128) ? tx_index : 127];
  always @(negedge sd_clk) if (rst_n && tx_take) tx_index <= tx_index + 1;

  task automatic arm_read;
    begin
      wait (!rx_busy);
      line_dir = 1'b0;
      line_start = 1'b1;
      wait (rx_busy);
      @(negedge sd_clk) line_start = 1'b0;
    end
  endtask

  task automatic arm_write;
    begin
      wait (!tx_busy);
      line_dir = 1'b1;
      line_start = 1'b1;
      wait (tx_busy);
      @(negedge sd_clk) line_start = 1'b0;
    end
  endtask

  initial begin
    logic [31:0] first_word;
    rst_n = 1'b0;
    checks = 0;
    failures = 0;
    req_valid = 0;
    req_index = 0;
    req_arg = 0;
    req_resp = RESP_NONE;
    req_is_acmd = 0;
    bus_wide = 1'b0;
    line_start = 0;
    line_dir = 0;
    rx_count = 0;
    tx_index = 0;
    inj_cmd_timeout = 0;
    inj_cmd_crc = 0;
    inj_data_crc = 0;
    inj_write_crc = 0;
    inj_busy_stuck = 0;
    for (int i = 0; i < 128; i++)
      tx_words[i] = {8'(4*i+3), 8'(4*i+2), 8'(4*i+1), 8'(4*i)} ^ 32'hD0D0_D0D0;

    repeat (5) @(posedge sd_clk);
    rst_n = 1'b1;
    repeat (3) @(posedge sd_clk);

    issue(CMD0_GO_IDLE_STATE, 0, RESP_NONE, 0);
    issue(CMD8_SEND_IF_COND, 32'h0000_01aa, RESP_R7, 0);
    check(!rsp_err && rsp_crc_ok && rsp_data[19:8] == 12'h1aa,
          "CMD8 R7 echo and CRC");

    issue(ACMD41_SD_SEND_OP_COND, 32'h40ff_8000, RESP_R3, 1);
    check(!rsp_data[39], "first ACMD41 reports card busy");
    issue(ACMD41_SD_SEND_OP_COND, 32'h40ff_8000, RESP_R3, 1);
    check(rsp_data[39] && rsp_data[38], "second ACMD41 reports ready and CCS");

    issue(CMD2_ALL_SEND_CID, 0, RESP_R2, 0);
    issue(CMD3_SEND_RELATIVE_ADDR, 0, RESP_R6, 0);
    check(rsp_data[39:24] == 16'h1234, "CMD3 returns configured RCA");
    issue(CMD9_SEND_CSD, 32'h1234_0000, RESP_R2, 0);
    issue(CMD7_SELECT_CARD, 32'h1234_0000, RESP_R1, 0);

    issue(ACMD6_SET_BUS_WIDTH, 32'h0000_0002, RESP_R1, 1);
    check(vip_wide, "ACMD6 selects four-bit data mode");
    bus_wide = 1'b1;

    issue(CMD6_SWITCH_FUNC, 32'h80ff_fff1, RESP_R1, 0);
    wait (u_card.dat_tx_state_q != 0);
    wait (u_card.dat_tx_state_q == 0);
    check(vip_hs, "CMD6 selects High Speed and emits switch-status data");

    // A complete 512-byte read through the real line engine.
    rx_count = 0;
    arm_read();
    issue(CMD17_READ_SINGLE_BLOCK, 32'd3, RESP_R1, 0);
    wait (rx_done);
    first_word = {u_card.read_byte(3*512+3), u_card.read_byte(3*512+2),
                  u_card.read_byte(3*512+1), u_card.read_byte(3*512+0)};
    check(rx_crc_ok && rx_count == 128, "CMD17 transfers one CRC-clean block");
    check(rx_words[0] == first_word, "CMD17 payload matches card storage");

    // Corrupt the card CRC and prove the host detects it.
    rx_count = 0;
    inj_data_crc = 1'b1;
    arm_read();
    issue(CMD17_READ_SINGLE_BLOCK, 32'd4, RESP_R1, 0);
    wait (rx_done);
    check(!rx_crc_ok, "read CRC fault injection is observable");
    inj_data_crc = 1'b0;

    // A complete write, accepted token and backdoor storage check.
    tx_index = 0;
    issue(CMD24_WRITE_BLOCK, 32'd5, RESP_R1, 0);
    arm_write();
    wait (tx_done);
    check(tx_status_ok && !tx_status_tmo && tx_status == 3'b010,
          "CMD24 returns accepted CRC-status token");
    wait (!card_busy);
    check(u_card.read_byte(5*512+0) == 8'hd0 &&
          u_card.read_byte(5*512+1) == 8'hd1,
          "CMD24 commits payload to card storage");

    // Reject a correct host block through fault injection.  Rejected data
    // must not leak into the backing store.
    tx_index = 0;
    inj_write_crc = 1'b1;
    issue(CMD24_WRITE_BLOCK, 32'd6, RESP_R1, 0);
    arm_write();
    wait (tx_done);
    check(!tx_status_ok && tx_status == 3'b101,
          "write CRC fault injection returns CRC-error token");
    check(u_card.read_byte(6*512+0) == (8'hA5 ^ 8'h00),
          "CRC-rejected write does not commit storage");
    inj_write_crc = 1'b0;
    wait (!card_busy);

    // Busy can be held indefinitely and resumes normally when the injection
    // is removed.
    tx_index = 0;
    inj_busy_stuck = 1'b1;
    issue(CMD24_WRITE_BLOCK, 32'd7, RESP_R1, 0);
    arm_write();
    wait (tx_done);
    wait (card_busy);
    repeat (12) @(posedge sd_clk);
    check(card_busy, "stuck-busy injection holds DAT0 low");
    inj_busy_stuck = 1'b0;
    wait (!card_busy);

    // Command-response CRC corruption must trigger the host's retry path.
    inj_cmd_crc = 1'b1;
    issue(CMD13_SEND_STATUS, 32'h1234_0000, RESP_R1, 0);
    inj_cmd_crc = 1'b0;
    // Deneme hakki tukendi: sayac artmis olmali ve FSM C_RETRY'de takilmamali.
    check(rsp_err && cmd_err == ERR_CMD_CRC && stat_retry_cmd != 16'd0,
          "command CRC injection exhausts retry and reports ERR_CMD_CRC");

    inj_cmd_timeout = 1'b1;
    issue(CMD13_SEND_STATUS, 32'h1234_0000, RESP_R1, 0);
    inj_cmd_timeout = 1'b0;
    check(rsp_err && cmd_err == ERR_CMD_TIMEOUT,
          "command timeout injection exhausts retry and reports timeout");

    check(!vip_protocol_error, "VIP saw no malformed host command");
    check(vip_command_count >= 16, "VIP command accounting includes CMD55 prefixes");

    if (failures) begin
      $display("tb_sd_card_model: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_sd_card_model: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    #2_000_000;
    $fatal(1, "tb_sd_card_model timeout");
  end
endmodule

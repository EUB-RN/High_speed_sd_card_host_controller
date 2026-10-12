`timescale 1ns/1ps

// Initialization policy and command transport are tested together through
// ultra_sd_protocol against responses driven on the actual CMD interface.
module tb_init_ladder_basic;
  import ultra_sd_pkg::*;

  logic cmd_clk = 0;
  logic rst_n, card_present_i, ramp_done_i;
  logic init_busy_o, init_done_o, init_err_o;
  err_e init_err_code_o;
  logic req_ready_o, rsp_valid_o, rsp_crc_ok_o, rsp_err_o;
  logic [RESP_LONG_BITS-1:0] rsp_data_o;
  err_e err_o;
  logic card_ready_o;
  logic dat_rd_start_o;
  logic [10:0] dat_rd_bytes_o;
  logic [31:0] dat_rd_data_i;
  logic dat_rd_valid_i, dat_rd_busy_i, dat_rd_crc_ok_i;
  logic [15:0] rca_o;
  logic [31:0] card_blk_o;
  speed_e speed_o;
  logic bus_4bit_o;
  logic [CFG_CLK_W-1:0] clk_div_o;
  logic [15:0] stat_retry_cmd_o;
  logic cmd_out, cmd_oe, cmd_in;
  logic [31:0] cap_arg;
  resp_e idle_resp;
  initial idle_resp = RESP_NONE;
  int checks, failures;

  always #5 cmd_clk = ~cmd_clk;

  ultra_sd_protocol #(
    .NCR_TIMEOUT_CLK(16), .NCC_GAP_CLK(2), .CMD_RETRIES(1),
    .CLK_DIV_INIT(20), .CLK_DIV_DS(4), .CLK_DIV_HS(2),
    .ACMD41_TIMEOUT_CLK(32), .DAT_TIMEOUT_CLK(32),
    .SCR_CHECK(1'b0), .HS_ENABLE(1'b0)
  ) dut (
    .cmd_clk, .rst_n, .soft_clr(1'b0),
    // L3 portu bos: merdiven hatta sahip.
    .req_valid_i(1'b0), .req_index_i(6'd0), .req_arg_i(32'h0),
    .req_resp_i(idle_resp), .req_is_acmd_i(1'b0), .req_ready_o(req_ready_o),
    .rsp_valid_o(rsp_valid_o), .rsp_data_o(rsp_data_o),
    .rsp_crc_ok_o(rsp_crc_ok_o), .rsp_err_o(rsp_err_o), .err_o(err_o),
    .card_ready_o(card_ready_o),
    .card_present_i, .ramp_done_i, .force_1bit_i(1'b0), .force_ds_i(1'b0),
    .init_busy_o, .init_done_o, .init_err_o, .init_err_code_o,
    .dat_rd_start_o, .dat_rd_bytes_o,
    .dat_rd_data_i, .dat_rd_valid_i, .dat_rd_busy_i, .dat_rd_crc_ok_i,
    .rca_o, .card_blk_o, .speed_o, .bus_4bit_o, .clk_div_o,
    .stat_clear_tgl_i(1'b0), .stat_retry_cmd_o(stat_retry_cmd_o),
    .cmd_out_o(cmd_out), .cmd_oe_o(cmd_oe), .cmd_in_i(cmd_in)
  );

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin failures++; $display("FAIL: %s", message); end
  endtask

`include "cmd_line_resp.svh"

  initial begin
    logic [119:0] csd;
    checks = 0; failures = 0;
    rst_n = 0; card_present_i = 0; ramp_done_i = 0;
    cmd_in = 1;
    dat_rd_data_i = 0; dat_rd_valid_i = 0; dat_rd_busy_i = 0; dat_rd_crc_ok_i = 1;
    repeat (3) @(posedge cmd_clk); rst_n = 1; repeat (2) @(posedge cmd_clk);
    check(!init_busy_o && !init_done_o && !init_err_o, "reset state");

    card_present_i = 1; ramp_done_i = 1;

    // CMD0: yanitsiz.
    capture_command(CMD0_GO_IDLE_STATE);

    capture_command(CMD8_SEND_IF_COND);
    send_short(CMD8_SEND_IF_COND, 32'h000001aa, 1);

    // ACMD41: once CMD55, sonra komutun kendisi. R3'un CRC'si anlamsizdir.
    capture_command(CMD55_APP_CMD);
    check(cap_arg == 32'h0000_0000, "CMD55 before ACMD41 carries RCA 0");
    send_short(CMD55_APP_CMD, 32'h00000100, 1);
    capture_command(ACMD41_SD_SEND_OP_COND);
    check(cap_arg == 32'h40ff_8000, "ACMD41 asks for the configured OCR");
    send_short(6'h3f, 32'hc0000000, 0);

    capture_command(CMD2_ALL_SEND_CID);
    csd = '0; send_long(csd);

    capture_command(CMD3_SEND_RELATIVE_ADDR);
    send_short(CMD3_SEND_RELATIVE_ADDR, 32'h12340000, 1);

    capture_command(CMD9_SEND_CSD);
    check(cap_arg == 32'h1234_0000, "CMD9 addresses the negotiated RCA");
    csd = {120{1'b1}}; csd[119:118] = 2'b01; csd[61:40] = 22'h2A_95C3; send_long(csd);

    capture_command(CMD7_SELECT_CARD);
    send_short(CMD7_SELECT_CARD, 32'h00000100, 1);

    capture_command(CMD55_APP_CMD);
    check(cap_arg == 32'h1234_0000, "CMD55 before ACMD6 carries the RCA");
    send_short(CMD55_APP_CMD, 32'h00000100, 1);
    capture_command(ACMD6_SET_BUS_WIDTH);
    // SCR_CHECK kapali: merdiven 4-bit'i varsayar, yani arg = 2.
    check(cap_arg == 32'h0000_0002, "ACMD6 requests 4-bit mode");
    send_short(ACMD6_SET_BUS_WIDTH, 32'h00000100, 1);

    repeat (10) @(posedge cmd_clk); #1;

    check(init_done_o && !init_busy_o && !init_err_o && init_err_code_o == ERR_OK,
          "initialisation completes cleanly");
    check(rca_o == 16'h1234, "RCA decoded");
    check(card_blk_o == ((32'h002A_95C3 + 32'd1) << 10), "CSD v2 capacity decoded");
    check(bus_4bit_o, "4-bit mode selected");
    check(speed_o == SPEED_DS && clk_div_o == 8'd4, "Default Speed selected");
    check(stat_retry_cmd_o == 16'd0, "clean ladder spends no command retry");

    card_present_i = 0;
    // Kart varligi artik iki flopluk senkronizerden geciyor (cdc.md 8), yani
    // temizlik iki SD cevrimi sonra olur. Bekleme suresi sozlesmenin parcasi:
    // tek cevrim bekleyip "temizlenmedi" demek senkronizeri hata sayardi.
    repeat (3) @(posedge cmd_clk); #1;
    check(!init_done_o && rca_o == 0 && card_blk_o == 0, "card removal clears state");

    // An SDSC card -- OCR.CCS = 0 -- is byte-addressed and out of scope
    // (Section 3.2, R-FUNC-5). The ladder has to stop at ACMD41 rather than
    // carry a second addressing mode through every layer below it.
    card_present_i = 1;
    repeat (3) @(posedge cmd_clk);
    capture_command(CMD0_GO_IDLE_STATE);
    capture_command(CMD8_SEND_IF_COND);
    send_short(CMD8_SEND_IF_COND, 32'h000001aa, 1);
    capture_command(CMD55_APP_CMD);
    send_short(CMD55_APP_CMD, 32'h00000100, 1);
    capture_command(ACMD41_SD_SEND_OP_COND);
    send_short(6'h3f, 32'h80000000, 0);   // powered up, CCS = 0
    repeat (6) @(posedge cmd_clk); #1;
    check(init_err_o && !init_done_o && init_err_code_o == ERR_UNSUPPORTED,
          "SDSC card (CCS = 0) is rejected as unsupported");

    if (failures) begin
      $display("tb_init_ladder_basic: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_init_ladder_basic: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin #4_000_000; $fatal(1, "tb_init_ladder_basic timeout"); end
endmodule

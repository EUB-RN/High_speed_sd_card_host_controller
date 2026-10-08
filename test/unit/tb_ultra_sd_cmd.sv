`timescale 1ns/1ps

module tb_ultra_sd_cmd;
  import ultra_sd_pkg::*;

  logic cmd_clk = 0, rst_n;
  logic req_valid_i, req_is_acmd_i, req_ready_o;
  logic [5:0] req_index_i;
  logic [31:0] req_arg_i;
  resp_e req_resp_i;
  logic rsp_valid_o, rsp_crc_ok_o, rsp_err_o;
  logic [RESP_LONG_BITS-1:0] rsp_data_o;
  err_e err_o;
  logic card_ready_o;

  // Baslatma merdiveni artik ayni modulde. Bu test SALT komut motorunu
  // siniyor: kart yok + rampa yok => merdiven I_IDLE'da kalir, init_active
  // alcaktir ve dis istek portu eskisi gibi hatta sahiptir. (rca_i portu yok
  // artik: CMD55 argumani merdivenin kendi rca_q'sundan geliyor.)
  logic card_present_i = 1'b0, ramp_done_i = 1'b0;
  logic init_busy_o, init_done_o, init_err_o;
  err_e init_err_code_o;
  logic dat_rd_start_o;
  logic [10:0] dat_rd_bytes_o;
  logic [31:0] dat_rd_data_i = 32'h0;
  logic dat_rd_valid_i = 1'b0, dat_rd_busy_i = 1'b0, dat_rd_crc_ok_i = 1'b1;
  logic [15:0] rca_o;
  logic [31:0] card_blk_o;
  logic block_addr_o, bus_4bit_o;
  speed_e speed_o;
  logic [CFG_CLK_W-1:0] clk_div_o;
  // Komut tekrarlarini artik DUT'un KENDISI sayiyor: sayac C_RETRY kolunun
  // yaninda, ultra_sd_cmd icinde (R-IF-11). Burada ham darbeyi tb'de toplamak
  // yerine o sayaci dogrudan okuyoruz -- olculen sey registerin gorecegi sey.
  logic        stat_clear_tgl_i;
  logic [15:0] stat_retry_cmd_o;
  int retry_events;
  logic cmd_out_o, cmd_oe_o, cmd_in_i;
  int checks, failures;
  initial stat_clear_tgl_i = 1'b0;

  always #5 cmd_clk = ~cmd_clk;

  always @(posedge cmd_clk) retry_events = int'(stat_retry_cmd_o);

  ultra_sd_cmd #(.NCR_TIMEOUT_CLK(4), .NCC_GAP_CLK(2), .CMD_RETRIES(1)) dut (.*);

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin failures++; $display("FAIL: %s", message); end
  endtask

  task automatic issue(input logic [5:0] index,
                       input logic [31:0] arg,
                       input resp_e response);
    while (!req_ready_o) @(posedge cmd_clk);
    @(negedge cmd_clk);
    req_index_i = index; req_arg_i = arg; req_resp_i = response;
    req_is_acmd_i = 0; req_valid_i = 1;
    @(posedge cmd_clk); #1;
    @(negedge cmd_clk); req_valid_i = 0;
  endtask

  initial begin
    logic [47:0] captured;
    int bit_count;
    int timeout;
    checks = 0; failures = 0; retry_events = 0;
    rst_n = 0; req_valid_i = 0; req_index_i = 0; req_arg_i = 0;
    req_resp_i = RESP_NONE; req_is_acmd_i = 0;
    cmd_in_i = 1;
    repeat (3) @(posedge cmd_clk); rst_n = 1; repeat (2) @(posedge cmd_clk);
    check(req_ready_o && !cmd_oe_o && !rsp_valid_o && err_o == ERR_OK,
          "reset/idle contract");

    issue(CMD0_GO_IDLE_STATE, 32'h0, RESP_NONE);
    captured = '0; bit_count = 0; timeout = 0;
    while (bit_count < 48 && timeout < 100) begin
      @(negedge cmd_clk); #1; timeout++;
      if (cmd_oe_o) begin
        captured = {captured[46:0], cmd_out_o};
        bit_count++;
      end
    end
    check(bit_count == 48, "CMD0 transmitted 48 bits");
    check(captured == 48'h400000000095, "CMD0 frame and CRC7");
    timeout = 0;
    while (!rsp_valid_o && timeout < 20) begin @(posedge cmd_clk); #1; timeout++; end
    check(rsp_valid_o && !rsp_err_o && err_o == ERR_OK, "CMD0 completes without response");

    // A response-bearing command with an idle-high card must terminate with a
    // bounded timeout after one retry, rather than hanging forever.
    issue(CMD8_SEND_IF_COND, 32'h000001aa, RESP_R7);
    timeout = 0;
    while (!rsp_valid_o && timeout < 180) begin @(posedge cmd_clk); #1; timeout++; end
    check(timeout < 180, "response timeout is bounded");
    check(rsp_err_o && err_o == ERR_CMD_TIMEOUT, "timeout error code");
    check(retry_events == 1, "one retry event reported");

    if (failures) begin
      $display("tb_ultra_sd_cmd: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_ultra_sd_cmd: PASSED (%0d checks)", checks);
    $finish;
  end
endmodule

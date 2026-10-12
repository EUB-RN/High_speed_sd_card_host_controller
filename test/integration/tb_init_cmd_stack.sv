`timescale 1ns/1ps

module tb_init_cmd_stack;
  import ultra_sd_pkg::*;

  logic cmd_clk = 0, rst_n, card_present, ramp_done;
  logic init_busy, init_done, init_err;
  err_e init_error;
  logic req_ready;
  logic rsp_valid, rsp_crc_ok, rsp_err;
  logic [RESP_LONG_BITS-1:0] rsp_data;
  err_e cmd_error;
  logic cmd_out, cmd_oe, cmd_in;
  logic card_ready;
  // Komut tekrarlarini ultra_sd_cmd kendi iciinde sayiyor; ham darbe portu
  // yok. Test o sayaci okuyor.
  logic [15:0] stat_retry_cmd;
  int retry_count;
  logic [15:0] rca;
  logic [31:0] card_blocks;
  speed_e speed;
  logic bus_4bit;
  logic [CFG_CLK_W-1:0] clk_div;
  logic dat_rd_start;
  logic [10:0] dat_rd_bytes;
  resp_e idle_resp;
  int checks, failures;

  always #5 cmd_clk = ~cmd_clk;
  always @(posedge cmd_clk) retry_count = int'(stat_retry_cmd);
  assign idle_resp = RESP_NONE;

  // Merdiven ve komut motoru artik TEK modul. Bu testin eski hali ikisini ayri
  // ornekliyor ve aradaki istek yolunu elle bagliyordu (ultra_sd_top'taki
  // arbitrasyon mux'unun aynisi); o kablolar modulun icine girdigi icin burada
  // hicbiri kalmadi. Sinanan sey degismedi: merdiven gercek CMD hatti uzerinde
  // kosuyor ve kart davranissal olarak yanitliyor.
  ultra_sd_protocol #(
    .NCR_TIMEOUT_CLK(16), .NCC_GAP_CLK(2), .CMD_RETRIES(1),
    .CLK_DIV_INIT(20), .CLK_DIV_DS(4), .CLK_DIV_HS(2),
    .ACMD41_TIMEOUT_CLK(100), .DAT_TIMEOUT_CLK(100),
    .SCR_CHECK(1'b0), .HS_ENABLE(1'b0)
  ) u_cmd (
    .cmd_clk, .rst_n, .soft_clr(1'b0),

    // L3 istek portu bu testte bos: merdiven hatta sahip.
    .req_valid_i(1'b0), .req_index_i(6'd0), .req_arg_i(32'h0),
    .req_resp_i(idle_resp), .req_is_acmd_i(1'b0), .req_ready_o(req_ready),
    .rsp_valid_o(rsp_valid), .rsp_data_o(rsp_data),
    .rsp_crc_ok_o(rsp_crc_ok), .rsp_err_o(rsp_err), .err_o(cmd_error),
    .card_ready_o(card_ready),

    .card_present_i(card_present), .ramp_done_i(ramp_done),
    .init_busy_o(init_busy), .init_done_o(init_done), .init_err_o(init_err),
    .init_err_code_o(init_error),

    .dat_rd_start_o(dat_rd_start), .dat_rd_bytes_o(dat_rd_bytes),
    .dat_rd_data_i(32'h0), .dat_rd_valid_i(1'b0), .dat_rd_busy_i(1'b0),
    .dat_rd_crc_ok_i(1'b1),

    .rca_o(rca), .card_blk_o(card_blocks),
    .speed_o(speed), .bus_4bit_o(bus_4bit), .clk_div_o(clk_div),

    .stat_clear_tgl_i(1'b0), .stat_retry_cmd_o(stat_retry_cmd),
    .cmd_out_o(cmd_out), .cmd_oe_o(cmd_oe), .cmd_in_i(cmd_in)
  );

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin failures++; $display("FAIL: %s", message); end
  endtask

  function automatic logic [6:0] crc7_40(input logic [39:0] value);
    logic [6:0] crc; logic fb;
    crc = 0;
    for (int i = 39; i >= 0; i--) begin
      fb = crc[6] ^ value[i];
      crc = {crc[5:0], 1'b0} ^ (fb ? 7'h09 : 7'h00);
    end
    return crc;
  endfunction

  function automatic logic [6:0] crc7_120(input logic [119:0] value);
    logic [6:0] crc; logic fb;
    crc = 0;
    for (int i = 119; i >= 0; i--) begin
      fb = crc[6] ^ value[i];
      crc = {crc[5:0], 1'b0} ^ (fb ? 7'h09 : 7'h00);
    end
    return crc;
  endfunction

  task automatic capture_command(input logic [5:0] expected_index);
    logic [47:0] frame;
    int n, timeout;
    frame = 0; n = 0; timeout = 0;
    while (n < 48 && timeout < 200) begin
      @(negedge cmd_clk); #1; timeout++;
      if (cmd_oe) begin frame = {frame[46:0], cmd_out}; n++; end
    end
    check(n == 48, "card saw complete command frame");
    check(frame[45:40] == expected_index,
          $sformatf("wire command expected CMD%0d got CMD%0d", expected_index,
                    frame[45:40]));
    check(frame[0] && frame[7:1] == crc7_40(frame[47:8]),
          "host command CRC7 and stop bit");
  endtask

  task automatic send_short(input logic [5:0] response_index,
                            input logic [31:0] argument,
                            input logic crc_meaningful);
    logic [47:0] frame;
    logic [39:0] header;
    header = {1'b0, 1'b0, response_index, argument};
    frame = {header, crc_meaningful ? crc7_40(header) : 7'h7f, 1'b1};
    // Let the host leave TX and enter the response window.
    @(posedge cmd_clk); @(negedge cmd_clk);
    for (int i = 47; i >= 0; i--) begin
      cmd_in = frame[i]; @(posedge cmd_clk); @(negedge cmd_clk);
    end
    cmd_in = 1;
  endtask

  task automatic send_long(input logic [119:0] content);
    logic [135:0] frame;
    frame = {8'h3f, content, crc7_120(content), 1'b1};
    @(posedge cmd_clk); @(negedge cmd_clk);
    for (int i = 135; i >= 0; i--) begin
      cmd_in = frame[i]; @(posedge cmd_clk); @(negedge cmd_clk);
    end
    cmd_in = 1;
  endtask

  initial begin
    logic [119:0] csd;
    checks = 0; failures = 0; retry_count = 0;
    rst_n = 0; card_present = 0; ramp_done = 0;
    cmd_in = 1;
    repeat (4) @(posedge cmd_clk); rst_n = 1; repeat (2) @(posedge cmd_clk);
    card_present = 1; ramp_done = 1;

    capture_command(CMD0_GO_IDLE_STATE); // no response
    capture_command(CMD8_SEND_IF_COND); send_short(CMD8_SEND_IF_COND, 32'h000001aa, 1);
    capture_command(CMD55_APP_CMD); send_short(CMD55_APP_CMD, 32'h00000100, 1);
    capture_command(ACMD41_SD_SEND_OP_COND); send_short(6'h3f, 32'hc0000000, 0);
    csd = 0; capture_command(CMD2_ALL_SEND_CID); send_long(csd);
    capture_command(CMD3_SEND_RELATIVE_ADDR); send_short(CMD3_SEND_RELATIVE_ADDR, 32'h12340000, 1);
    csd = 0; csd[119:118] = 2'b01; csd[61:40] = 22'd1023;
    capture_command(CMD9_SEND_CSD); send_long(csd);
    capture_command(CMD7_SELECT_CARD); send_short(CMD7_SELECT_CARD, 32'h00000100, 1);
    capture_command(CMD55_APP_CMD); send_short(CMD55_APP_CMD, 32'h00000100, 1);
    capture_command(ACMD6_SET_BUS_WIDTH); send_short(ACMD6_SET_BUS_WIDTH, 32'h00000100, 1);

    repeat (10) @(posedge cmd_clk); #1;
    check(init_done && !init_err && init_error == ERR_OK,
          "combined init+command stack completes");
    check(rca == 16'h1234 && card_blocks == 32'd1048576,
          "combined response decoding");
    check(bus_4bit && speed == SPEED_DS && retry_count == 0,
          "combined negotiated mode without retries");

    if (failures) begin
      $display("tb_init_cmd_stack: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_init_cmd_stack: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin #2_000_000; $fatal(1, "tb_init_cmd_stack timeout"); end
endmodule

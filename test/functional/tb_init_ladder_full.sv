`timescale 1ns/1ps

// Initialization policy and command transport are tested together through
// ultra_sd_protocol against responses driven on the actual CMD interface.
module tb_init_ladder_full;
  import ultra_sd_pkg::*;

  logic cmd_clk = 0;
  logic soft_clr = 0;
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
  // CFG_PHY geri cekilme bitleri; reset_case() ikisini de temizler, ozel
  // vakalar reset'ten SONRA kurar (merdiven kosarken orneklenirler).
  logic force_1bit_i, force_ds_i;
  logic cmd_out, cmd_oe, cmd_in;
  logic [31:0] cap_arg;
  resp_e idle_resp;
  initial idle_resp = RESP_NONE;
  int checks, failures;

  always #5 cmd_clk = ~cmd_clk;

  ultra_sd_protocol #(
    .NCR_TIMEOUT_CLK(16), .NCC_GAP_CLK(2), .CMD_RETRIES(1),
    .CLK_DIV_INIT(20), .CLK_DIV_DS(4), .CLK_DIV_HS(2),
    .ACMD41_TIMEOUT_CLK(32), .DAT_TIMEOUT_CLK(600),
    .SCR_CHECK(1'b1), .HS_ENABLE(1'b1)
  ) dut (
    .cmd_clk, .rst_n, .soft_clr,
    .req_valid_i(1'b0), .req_index_i(6'd0), .req_arg_i(32'h0),
    .req_resp_i(idle_resp), .req_is_acmd_i(1'b0), .req_ready_o(req_ready_o),
    .rsp_valid_o(rsp_valid_o), .rsp_data_o(rsp_data_o),
    .rsp_crc_ok_o(rsp_crc_ok_o), .rsp_err_o(rsp_err_o), .err_o(err_o),
    .card_ready_o(card_ready_o),
    .card_present_i, .ramp_done_i,
    .force_1bit_i, .force_ds_i,
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

  task automatic reset_case;
    rst_n = 0; card_present_i = 0; ramp_done_i = 0;
    force_1bit_i = 0; force_ds_i = 0;
    cmd_in = 1;
    dat_rd_data_i = 0; dat_rd_valid_i = 0; dat_rd_busy_i = 0; dat_rd_crc_ok_i = 1;
    repeat (4) @(posedge cmd_clk); rst_n = 1; repeat (2) @(posedge cmd_clk);
    card_present_i = 1; ramp_done_i = 1;
  endtask

  // CMD0 .. CMD7: kimlik ve secim. Sonrasi ACMD51 (SCR) ile devam eder.
  task automatic walk_to_scr(input logic [1:0] csd_structure);
    logic [119:0] csd;
    capture_command(CMD0_GO_IDLE_STATE);

    capture_command(CMD8_SEND_IF_COND);
    check(cap_arg == 32'h0000_01aa, "CMD8 sends the voltage check pattern");
    send_short(CMD8_SEND_IF_COND, 32'h000001aa, 1);

    capture_command(CMD55_APP_CMD);
    send_short(CMD55_APP_CMD, 32'h00000100, 1);
    capture_command(ACMD41_SD_SEND_OP_COND);
    send_short(6'h3f, 32'hc0000000, 0);

    capture_command(CMD2_ALL_SEND_CID);
    csd = '0; send_long(csd);

    capture_command(CMD3_SEND_RELATIVE_ADDR);
    send_short(CMD3_SEND_RELATIVE_ADDR, 32'h12340000, 1);

    capture_command(CMD9_SEND_CSD);
    check(cap_arg == 32'h1234_0000, "CMD9 addresses the negotiated RCA");
    csd = '0; csd[119:118] = csd_structure; csd[61:40] = 22'd1023; send_long(csd);

    capture_command(CMD7_SELECT_CARD);
    check(cap_arg == 32'h1234_0000, "CMD7 selects the negotiated RCA");
    send_short(CMD7_SELECT_CARD, 32'h00000100, 1);

    capture_command(CMD55_APP_CMD);
    send_short(CMD55_APP_CMD, 32'h00000100, 1);
    capture_command(ACMD51_SEND_SCR);
    send_short(ACMD51_SEND_SCR, 32'h00000100, 1);

    repeat (4) @(posedge cmd_clk); #1;
    check(dat_rd_start_o && dat_rd_bytes_o == 11'd8,
          "ACMD51 arms an 8-byte DAT read");
  endtask


  // CMD0 .. CMD9, ama CSD v1.0 (SDSC). Merdiven CMD9'un cevabinda durmali,
  // dolayisiyla walk_to_scr'in geri kalani (CMD7, ACMD51) hic kosmaz.
  task automatic walk_to_scr_sdsc;
    logic [119:0] csd;
    capture_command(CMD0_GO_IDLE_STATE);
    capture_command(CMD8_SEND_IF_COND);
    send_short(CMD8_SEND_IF_COND, 32'h000001aa, 1);
    capture_command(CMD55_APP_CMD);
    send_short(CMD55_APP_CMD, 32'h00000100, 1);
    capture_command(ACMD41_SD_SEND_OP_COND);
    send_short(6'h3f, 32'hc0000000, 0);
    capture_command(CMD2_ALL_SEND_CID);
    csd = '0; send_long(csd);
    capture_command(CMD3_SEND_RELATIVE_ADDR);
    send_short(CMD3_SEND_RELATIVE_ADDR, 32'h12340000, 1);
    capture_command(CMD9_SEND_CSD);
    csd = '0; csd[119:118] = 2'b00; csd[61:40] = 22'd1023; send_long(csd);
  endtask

  task automatic send_dat_frame(
    input int words,
    input logic [7:0] capability_byte,
    input logic crc_ok
  );
    dat_rd_busy_i = 1;
    @(posedge cmd_clk); #1;
    check(!dat_rd_start_o, "DAT start drops after busy acknowledgement");
    for (int i = 0; i < words; i++) begin
      @(negedge cmd_clk);
      dat_rd_data_i = 32'h0;
      if ((words == 2) && (i == 0)) dat_rd_data_i[15:8] = capability_byte;
      if ((words == 16) && (i == 4)) dat_rd_data_i[7:0] = capability_byte;
      dat_rd_valid_i = 1;
      @(posedge cmd_clk); #1;
    end
    @(negedge cmd_clk);
    dat_rd_valid_i = 0; dat_rd_busy_i = 0; dat_rd_crc_ok_i = crc_ok;
    @(posedge cmd_clk); #1;
    dat_rd_crc_ok_i = 1;
  endtask

  // SCR'den sonrasi: ACMD6 (bus width) + CMD6 (switch) + switch-status DAT'i.
  task automatic finish_after_scr(input logic [31:0] expect_acmd6_arg,
                                  input logic [7:0]  switch_byte);
    capture_command(CMD55_APP_CMD);
    send_short(CMD55_APP_CMD, 32'h00000100, 1);
    capture_command(ACMD6_SET_BUS_WIDTH);
    check(cap_arg == expect_acmd6_arg,
          $sformatf("ACMD6 argument %08h", expect_acmd6_arg));
    send_short(ACMD6_SET_BUS_WIDTH, 32'h00000100, 1);

    capture_command(CMD6_SWITCH_FUNC);
    check(cap_arg == 32'h80ff_fff1, "CMD6 switch argument follows ACMD6");
    send_short(CMD6_SWITCH_FUNC, 32'h00000100, 1);

    repeat (4) @(posedge cmd_clk); #1;
    check(dat_rd_start_o && dat_rd_bytes_o == 11'd64,
          "CMD6 arms a 64-byte switch-status read");
    send_dat_frame(16, switch_byte, 1);
  endtask

  initial begin
    checks = 0; failures = 0;

    // 1. Full capability path: SCR advertises 4-bit, switch status confirms HS.
    reset_case();
    walk_to_scr(2'b01);
    send_dat_frame(2, 8'h05, 1);
    finish_after_scr(32'h0000_0002, 8'h01);
    repeat (6) @(posedge cmd_clk); #1;
    check(init_done_o && !init_err_o && init_err_code_o == ERR_OK,
          "full SCR/High-Speed ladder completes");
    check(bus_4bit_o && speed_o == SPEED_HS && clk_div_o == 8'd2,
          "4-bit High-Speed result is committed");
    check(rca_o == 16'h1234 && card_blk_o == 32'd1_048_576,
          "identity and capacity survive full ladder");

    // 2. Graceful fallback: no 4-bit in SCR and switch result not HS.
    reset_case();
    walk_to_scr(2'b01);
    send_dat_frame(2, 8'h01, 1);
    finish_after_scr(32'h0000_0000, 8'h00);
    repeat (6) @(posedge cmd_clk); #1;
    check(init_done_o && !bus_4bit_o && speed_o == SPEED_DS && clk_div_o == 8'd4,
          "unsupported capabilities fall back to 1-bit Default Speed");

    // 3. A DAT CRC failure must not become a successful initialisation.
    reset_case();
    walk_to_scr(2'b01);
    send_dat_frame(2, 8'h05, 0);
    repeat (6) @(posedge cmd_clk); #1;
    check(init_err_o && !init_done_o && init_err_code_o == ERR_DAT_CRC,
          "SCR CRC corruption reports ERR_DAT_CRC");

    // 4. A card that answers ACMD51 but never starts DAT is bounded.
    reset_case();
    walk_to_scr(2'b01);
    repeat (700) @(posedge cmd_clk); #1;
    check(init_err_o && !init_done_o && init_err_code_o == ERR_DAT_TIMEOUT,
          "missing SCR payload reports bounded ERR_DAT_TIMEOUT");

    // 4b. CFG_PHY.FORCE_1BIT: kart 4-bit destekledigini SOYLESE bile host
    //     1-bit'te kalir -- ve kritik olan, bunu ACMD6'nin ARGUMANINDA yapar,
    //     yani kart da 1-bit'e gecer. Eskiden daraltma yalniz L1'in girisinde
    //     yapiliyordu: kart 4 hat surerken host DAT0'i okuyordu.
    reset_case();
    force_1bit_i = 1;
    walk_to_scr(2'b01);
    send_dat_frame(2, 8'h05, 1);              // SCR: 4-bit destekli
    finish_after_scr(32'h0000_0000, 8'h01);   // ACMD6 argumani 1-bit olmali
    repeat (6) @(posedge cmd_clk); #1;
    check(init_done_o && !bus_4bit_o,
          "FORCE_1BIT narrows the card as well as the host");
    check(speed_o == SPEED_HS,
          "FORCE_1BIT does not drag the speed down with it");

    // 4c. CFG_PHY.FORCE_DS: CMD6 switch'i hic denenmez, merdiven Default
    //     Speed'de biter. Genislik bundan etkilenmez.
    reset_case();
    force_ds_i = 1;
    walk_to_scr(2'b01);
    send_dat_frame(2, 8'h05, 1);
    capture_command(CMD55_APP_CMD);
    send_short(CMD55_APP_CMD, 32'h00000100, 1);
    capture_command(ACMD6_SET_BUS_WIDTH);
    check(cap_arg == 32'h0000_0002, "FORCE_DS leaves the 4-bit switch alone");
    send_short(ACMD6_SET_BUS_WIDTH, 32'h00000100, 1);
    repeat (8) @(posedge cmd_clk); #1;
    check(init_done_o && !init_err_o,
          "FORCE_DS completes the ladder without the switch");
    check(speed_o == SPEED_DS && clk_div_o == 8'd4 && bus_4bit_o,
          "FORCE_DS holds Default Speed at the DS divisor");
    check(!cmd_oe, "no CMD6 frame is driven under FORCE_DS");

    // 4d. SDSC (CSD v1.0) DESTEKLENMIYOR ve bu ACIKCA soyleniyor. Eskiden v2
    //     kapasite formulu kosulsuz calisiyor, kart "basariyla" baslatiliyor
    //     ve CARD_BLK cop cikiyordu (R-FUNC-5: sessizce yanlis islenmeyecek).
    reset_case();
    walk_to_scr_sdsc();
    repeat (8) @(posedge cmd_clk); #1;
    check(init_err_o && !init_done_o && init_err_code_o == ERR_UNSUPPORTED,
          "SDSC is rejected as unsupported, not silently mis-sized");
    check(card_blk_o == 32'd0, "a rejected card publishes no capacity");

    // 5. Voltage/check-pattern mismatch must stop before ACMD41.
    reset_case();
    capture_command(CMD0_GO_IDLE_STATE);
    capture_command(CMD8_SEND_IF_COND);
    send_short(CMD8_SEND_IF_COND, 32'h000001ab, 1);
    repeat (8) @(posedge cmd_clk); #1;
    check(init_err_o && init_err_code_o == ERR_UNSUPPORTED && !init_done_o,
          "bad CMD8 echo is rejected as unsupported");
    check(!init_busy_o, "rejected ladder raises no further request");

    // 6. A command the card never answers: the retry budget is spent and the
    //    command layer's own code reaches the ladder.
    reset_case();
    capture_command(CMD0_GO_IDLE_STATE);
    capture_and_drop(CMD8_SEND_IF_COND);   // first attempt
    capture_and_drop(CMD8_SEND_IF_COND);   // the one retry
    repeat (40) @(posedge cmd_clk); #1;
    check(init_err_o && init_err_code_o == ERR_CMD_TIMEOUT && !init_done_o,
          "command failure code propagates through init");
    check(stat_retry_cmd_o == 16'd1, "the spent command retry is counted");

    // 7. Removal from a completed state clears all learned card state.
    reset_case();
    walk_to_scr(2'b01);
    send_dat_frame(2, 8'h05, 1);
    finish_after_scr(32'h0000_0002, 8'h01);
    repeat (6) @(posedge cmd_clk); #1;
    check(init_done_o, "ladder completed before the eject");
    card_present_i = 0;
    repeat (3) @(posedge cmd_clk); #1;   // iki flopluk senkronizer (cdc.md 8)
    check(!init_done_o && !init_err_o && rca_o == 0 && card_blk_o == 0,
          "card removal clears completed initialization state");

    // Clear is the final override after the init FSM case statement.
    @(negedge cmd_clk); soft_clr = 1;
    repeat (2) @(posedge cmd_clk);
    #1;
    check(!init_busy_o && !init_done_o && !init_err_o,
          "soft clear overrides initialization state");
    check(rca_o == 0 && card_blk_o == 0 && speed_o == SPEED_INIT,
          "soft clear resets negotiated card configuration");
    @(negedge cmd_clk); soft_clr = 0;

    if (failures) begin
      $display("tb_init_ladder_full: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_init_ladder_full: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin #20_000_000; $fatal(1, "tb_init_ladder_full timeout"); end
endmodule

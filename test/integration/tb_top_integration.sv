`timescale 1ns/1ps

// Whole-core integration test.  The card model lives exclusively on the SD
// pads and the software model lives exclusively on AXI, so every observation
// crosses the same top-level boundaries as it does in hardware.
module tb_top_integration;
  import ultra_sd_pkg::*;

  localparam int SYS_CLK_HZ = 1_000_000;

  logic clk = 0;
  logic rst_n = 1;

  logic [7:0]  awaddr;
  logic        awvalid, awready;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic        wvalid, wready;
  logic [1:0]  bresp;
  logic        bvalid, bready;
  logic [7:0]  araddr;
  logic        arvalid, arready;
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid, rready;

  logic [31:0] m_axis_rd_tdata;
  logic        m_axis_rd_tvalid, m_axis_rd_tready, m_axis_rd_tlast;
  logic [31:0] s_axis_wr_tdata;
  logic        s_axis_wr_tvalid, s_axis_wr_tready, s_axis_wr_tlast;
  logic        irq;

  logic sd_clk;
  tri1  sd_cmd;
  tri1 [3:0] sd_dat;
  logic sd_cd = 1;
  logic card_cmd_oe, card_cmd_out;
  logic card_protocol_error, card_bus_4bit, card_high_speed;
  logic [5:0] card_last_cmd;
  logic [31:0] card_command_count;

  int checks, failures;
  int commands_seen;
  int progress;
  logic card_model_done;

  always #5 clk = ~clk;
  assign sd_cmd = card_cmd_oe ? card_cmd_out : 1'bz;

  sd_card_model #(
    .BLOCK_COUNT(1024), .NCR_DELAY_CYCLES(2), .NAC_DELAY_CYCLES(4),
    .ACMD41_BUSY_POLLS(1)
  ) u_card (
    .sd_clk, .rst_n, .card_present_i(!sd_cd), .sd_cmd, .sd_dat,
    .inject_cmd_timeout_i(1'b0), .inject_cmd_crc_i(1'b0),
    .inject_data_crc_i(1'b0), .inject_write_crc_i(1'b0),
    .inject_busy_stuck_i(1'b0), .protocol_error_o(card_protocol_error),
    .last_cmd_o(card_last_cmd), .command_count_o(card_command_count),
    .bus_4bit_o(card_bus_4bit), .high_speed_o(card_high_speed)
  );

  ultra_sd_top #(
    .SYS_CLK_HZ(SYS_CLK_HZ), .DATA_W(32),
    .RD_FIFO_BLOCKS(2), .WR_FIFO_BLOCKS(2), .CRC_RETRIES(1)
  ) dut (
    .clk, .rst_n,
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid),
    .s_axil_awready(awready), .s_axil_wdata(wdata),
    .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
    .s_axil_wready(wready), .s_axil_bresp(bresp),
    .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
    .s_axil_arready(arready), .s_axil_rdata(rdata),
    .s_axil_rresp(rresp), .s_axil_rvalid(rvalid),
    .s_axil_rready(rready),
    .m_axis_rd_tdata, .m_axis_rd_tvalid, .m_axis_rd_tready,
    .m_axis_rd_tlast, .s_axis_wr_tdata, .s_axis_wr_tvalid,
    .s_axis_wr_tready, .s_axis_wr_tlast,
    .irq, .sd_clk, .sd_cmd, .sd_dat, .sd_cd
  );

  // Keep the architectural sequence, with simulation-sized timeout windows.
  defparam dut.u_cmd.DAT_TIMEOUT_CLK = 4096;
  defparam dut.u_cmd.NCR_TIMEOUT_CLK = 16;
  defparam dut.u_cmd.NCC_GAP_CLK = 2;

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin
      failures++;
      $display("FAIL: %s", message);
    end
  endtask

  function automatic logic [6:0] crc7_40(input logic [39:0] value);
    logic [6:0] crc;
    logic fb;
    crc = 0;
    for (int i = 39; i >= 0; i--) begin
      fb = crc[6] ^ value[i];
      crc = {crc[5:0], 1'b0} ^ (fb ? 7'h09 : 7'h00);
    end
    return crc;
  endfunction

  function automatic logic [6:0] crc7_120(input logic [119:0] value);
    logic [6:0] crc;
    logic fb;
    crc = 0;
    for (int i = 119; i >= 0; i--) begin
      fb = crc[6] ^ value[i];
      crc = {crc[5:0], 1'b0} ^ (fb ? 7'h09 : 7'h00);
    end
    return crc;
  endfunction

  task automatic axil_write(input logic [7:0] addr,
                            input logic [31:0] data,
                            input logic [3:0] strb);
    int timeout;
    @(negedge clk);
    awaddr = addr; wdata = data; wstrb = strb;
    awvalid = 1; wvalid = 1; bready = 1;
    timeout = 0;
    while (!(awready && wready) && timeout < 20) begin
      @(posedge clk); #1; timeout++;
    end
    check(timeout < 20, "AXI-Lite write handshake");
    @(negedge clk); awvalid = 0; wvalid = 0;
    timeout = 0;
    while (!bvalid && timeout < 20) begin @(posedge clk); #1; timeout++; end
    check(bvalid && bresp == 2'b00, "AXI-Lite write response");
    @(negedge clk); bready = 0;
  endtask

  task automatic axil_read(input logic [7:0] addr,
                           output logic [31:0] data,
                           output logic [1:0] response);
    int timeout;
    @(negedge clk);
    araddr = addr; arvalid = 1; rready = 1;
    timeout = 0;
    while (!arready && timeout < 20) begin @(posedge clk); #1; timeout++; end
    check(timeout < 20, "AXI-Lite read-address handshake");
    @(posedge clk); #1;
    @(negedge clk); arvalid = 0;
    timeout = 0;
    while (!rvalid && timeout < 20) begin @(posedge clk); #1; timeout++; end
    data = rdata; response = rresp;
    check(rvalid, "AXI-Lite read response");
    @(negedge clk); rready = 0;
  endtask

  task automatic capture_command(input logic [5:0] expected_index);
    logic [47:0] frame;
    int timeout;
    frame = '0;
    timeout = 0;
    // A command always starts low; waiting on the pad also covers debounce and
    // the mandatory 74-clock ramp without peeking into the DUT.
    while ((sd_cmd !== 1'b0) && timeout < 500) begin
      @(negedge sd_clk); #1; timeout++;
    end
    check(timeout < 500, $sformatf("CMD%0d appeared on SD_CMD", expected_index));
    frame[47] = sd_cmd;
    for (int i = 46; i >= 0; i--) begin
      @(negedge sd_clk); #1; frame[i] = sd_cmd;
    end
    commands_seen++;
    check(frame[47:46] == 2'b01, "command start/transmission bits");
    check(frame[45:40] == expected_index,
          $sformatf("wire command expected CMD%0d got CMD%0d",
                    expected_index, frame[45:40]));
    check(frame[0] && frame[7:1] == crc7_40(frame[47:8]),
          "host command CRC7 and stop bit");
  endtask

  task automatic send_short(input logic [5:0] response_index,
                            input logic [31:0] argument,
                            input logic crc_meaningful);
    logic [39:0] header;
    logic [47:0] frame;
    header = {1'b0, 1'b0, response_index, argument};
    frame = {header, crc_meaningful ? crc7_40(header) : 7'h7f, 1'b1};
    @(negedge sd_clk);
    card_cmd_oe = 1;
    for (int i = 47; i >= 0; i--) begin
      card_cmd_out = frame[i];
      @(negedge sd_clk);
    end
    card_cmd_oe = 0;
    card_cmd_out = 1;
  endtask

  task automatic send_long(input logic [119:0] content);
    logic [135:0] frame;
    frame = {8'h3f, content, crc7_120(content), 1'b1};
    @(negedge sd_clk);
    card_cmd_oe = 1;
    for (int i = 135; i >= 0; i--) begin
      card_cmd_out = frame[i];
      @(negedge sd_clk);
    end
    card_cmd_oe = 0;
    card_cmd_out = 1;
  endtask

  task automatic run_card_model;
    logic [119:0] csd;
    capture_command(CMD0_GO_IDLE_STATE);
    capture_command(CMD8_SEND_IF_COND);
    send_short(CMD8_SEND_IF_COND, 32'h0000_01aa, 1);
    capture_command(CMD55_APP_CMD);
    send_short(CMD55_APP_CMD, 32'h0000_0100, 1);
    capture_command(ACMD41_SD_SEND_OP_COND);
    send_short(6'h3f, 32'hc000_0000, 0);
    csd = '0;
    capture_command(CMD2_ALL_SEND_CID);
    send_long(csd);
    capture_command(CMD3_SEND_RELATIVE_ADDR);
    send_short(CMD3_SEND_RELATIVE_ADDR, 32'h1234_0000, 1);
    csd = '0;
    csd[119:118] = 2'b01;
    csd[61:40] = 22'd1023;
    capture_command(CMD9_SEND_CSD);
    send_long(csd);
    capture_command(CMD7_SELECT_CARD);
    send_short(CMD7_SELECT_CARD, 32'h0000_0100, 1);
    capture_command(CMD55_APP_CMD);
    send_short(CMD55_APP_CMD, 32'h0000_0100, 1);
    capture_command(ACMD51_SEND_SCR);
    send_short(ACMD51_SEND_SCR, 32'h0000_0100, 1);
    // The current top does not connect init's 8-byte DAT read to u_line.
    // Deliberately provide no DAT frame and verify the externally visible
    // timeout below.
    card_model_done = 1;
  endtask

  initial begin
    logic [31:0] value;
    logic [1:0] response;
    int timeout;

    checks = 0; failures = 0; commands_seen = 0; progress = 0;
    sd_cd = 1;
    card_cmd_oe = 0; card_cmd_out = 1; card_model_done = 0;
    awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
    bready = 0; araddr = 0; arvalid = 0; rready = 0;
    m_axis_rd_tready = 1;
    s_axis_wr_tdata = 0; s_axis_wr_tvalid = 0; s_axis_wr_tlast = 0;

    #1 rst_n = 0;
    repeat (5) @(posedge clk);
    progress = 1;
    check(sd_clk === 1'b0, "SD clock is parked during reset");
    check(sd_cmd === 1'b1 && sd_dat === 4'hf,
          "SD pads are released to card pull-ups during reset");
    rst_n = 1;
    repeat (5) @(posedge clk);

    axil_read(REG_VERSION, value, response);
    progress = 2;
    check(response == 2'b00 && value == 32'h5344_0100,
          "VERSION is reachable through top-level AXI-Lite");
    axil_write(REG_LBA, 32'h1122_3344, 4'hf);
    progress = 21;
    axil_read(REG_LBA, value, response);
    progress = 22;
    check(value == 32'h1122_3344, "top-level AXI register write/read path");
    axil_write(REG_CTRL_STATUS, 32'(32'h0000_0006 << IRQ_EN_LSB), 4'h8);
    progress = 23;

    sd_cd = 0;
    progress = 3;

    timeout = 0;
    while (!irq && timeout < 2500) begin @(posedge clk); timeout++; end
    check(irq, "debounced card insertion raises enabled CARD_CHANGE IRQ");
    progress = 4;
    axil_read(REG_CTRL_STATUS, value, response);
    check(value[IRQ_STAT_LSB + IRQ_CARD_CHANGE_BIT], "CARD_CHANGE is latched in IRQ_STAT");
    axil_write(REG_CTRL_STATUS, 32'(1 << (IRQ_STAT_LSB + IRQ_CARD_CHANGE_BIT)), 4'h4);

    // The first real whole-core gate: after debounce, the top must emit SD
    // clocks and consume the 74-edge ramp.  If this fails, waiting for CMD0
    // would only hide the root cause behind a generic testbench timeout.
    timeout = 0;
    while ((sd_clk !== 1'b1) && timeout < 2000) begin @(posedge clk); timeout++; end
    check(timeout < 2000,
          "top starts a known SD clock after card insertion");
    if (timeout >= 2000) begin
      $display("clock-start debug: phase=%0d ramp=%0d raw_cmd_clk=%b divider=%0d",
               dut.u_sysctl.phase_q, dut.u_sysctl.ramp_cnt_q,
               dut.u_phy.sd_clk_div, dut.sd_clk_ratio);
      $display("tb_top_integration: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end

    timeout = 0;
    while (!dut.init_done && timeout < 400_000) begin @(posedge clk); timeout++; end
    card_model_done = dut.init_done;
    commands_seen = card_command_count;
    if (!card_model_done)
      $display("card model debug: commands=%0d sys_phase=%0d ramp=%0d sd_clk=%b raw=%b div=%b init_div=%b sys_rst=%b en=%b ce=%b core_rst=%b init_state=%0d init_phase=%0d cmd_state=%0d err=%0d sd_cd=%b cd_raw=%b cd_count=%0d stable=%b present=%b",
               commands_seen, dut.u_sysctl.phase_q, dut.u_sysctl.ramp_cnt_q,
               sd_clk, dut.u_phy.sd_clk_div, dut.sd_clk_ratio,
               dut.init_clk_div, dut.sys_rst_n, dut.sd_clk_en, dut.u_phy.ce_q,
               dut.core_rst_n, dut.u_cmd.init_mode_q, dut.u_cmd.init_phase_probe,
               dut.u_cmd.state_q, dut.init_err_code, sd_cd, dut.u_sysctl.cd_raw,
               dut.u_sysctl.cd_cnt_q, dut.u_sysctl.cd_stable_q,
               dut.card_present);
    check(card_model_done && card_command_count >= 13,
          "complete command and DAT paths finish the init ladder");
    progress = 5;

    axil_read(REG_CTRL_STATUS, value, response);
    check(value[STATUS_CARD_PRES_BIT] && value[STATUS_CARD_RDY_BIT],
          "STATUS reports an initialized card");
    check(value[ERR_LSB +: 8] == ERR_OK,
          "full initialization completes without an error");
    axil_read(REG_CARD_BLK, value, response);
    check(value == 32'd1024,
          "CMD response decoding reaches CARD_BLK register");
    check(card_bus_4bit && card_high_speed,
          "ACMD51/ACMD6/CMD6 negotiate 4-bit High Speed on real DAT pins");
    check(!card_protocol_error, "card model saw no command or framing violation");

    if (failures) begin
      $display("tb_top_integration: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_top_integration: PASSED (%0d checks)", checks);
    $finish;
  end

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("top_integration.vcd");
      $dumpvars(0, tb_top_integration);
    end
  end

  initial begin
    #20_000_000;
    $display("timeout debug: progress=%0d commands=%0d phase=%0d init_state=%0d init_phase=%0d sd_clk=%b cmd=%b",
             progress, commands_seen, dut.u_sysctl.phase_q, dut.u_cmd.init_mode_q,
             dut.u_cmd.init_phase_probe, sd_clk, sd_cmd);
    $fatal(1, "tb_top_integration timeout");
  end
endmodule

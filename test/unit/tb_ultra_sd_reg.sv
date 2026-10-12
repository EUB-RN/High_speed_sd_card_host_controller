`timescale 1ns/1ps

module tb_ultra_sd_reg;
  import ultra_sd_pkg::*;

  logic clk = 0;
  logic rst_n;
  logic wr_en;
  logic [31:0] wr_addr, wr_data;
  logic [3:0] wr_strb;
  logic [1:0] bresp_r;
  logic rd_en;
  logic [31:0] rd_addr, rd_data;
  logic [1:0] rresp_r;
  logic [CTRL_W-1:0] CTRL;
  logic [LBA_W-1:0] LBA;
  logic [BLOCKS_W-1:0] BLOCKS;
  logic XFER;
  logic [CFG_CLK_W-1:0] CFG_CLK;
  logic [CFG_PHY_W-1:0] CFG_PHY;
  logic [STATUS_W-1:0] STATUS;
  err_e ERR;
  logic [31:0] CARD_BLK, STAT_DATA, STAT_GAP, STAT_BUSY, STAT_RETRY;
  logic [IRQ_W-1:0] IRQ_SET;
  logic [CFG_CLK_W-1:0] CFG_CLK_HW;
  logic irq;
  int checks;
  int failures;

  always #5 clk = ~clk;

  ultra_sd_reg dut (.*);

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin failures++; $display("FAIL: %s", message); end
  endtask

  task automatic write_reg(input logic [31:0] addr,
                           input logic [31:0] data,
                           input logic [3:0] strb);
    @(negedge clk);
    wr_addr = addr; wr_data = data; wr_strb = strb; wr_en = 1'b1;
    @(posedge clk); #1;
    @(negedge clk); wr_en = 1'b0;
  endtask

  task automatic read_check(input logic [31:0] addr,
                            input logic [31:0] expected,
                            input string message);
    @(negedge clk); rd_addr = addr; rd_en = 1'b1; #1;
    check(rresp_r == 2'b00, {message, " response"});
    check(rd_data == expected, message);
    @(negedge clk); rd_en = 1'b0;
  endtask

  initial begin
    checks = 0; failures = 0;
    rst_n = 0; wr_en = 0; rd_en = 0; wr_addr = 0; wr_data = 0; wr_strb = 0;
    rd_addr = 0; STATUS = 8'ha5; ERR = ERR_DAT_CRC; CARD_BLK = 32'h12345678;
    STAT_DATA = 32'h11; STAT_GAP = 32'h22; STAT_BUSY = 32'h33;
    STAT_RETRY = 32'h44556677; IRQ_SET = 0; CFG_CLK_HW = 8'hff;
    repeat (3) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);

    check(CTRL == 0 && LBA == 0 && BLOCKS == 1 && XFER == 0,
          "reset request registers");
    check(CFG_CLK == 8'hff && CFG_PHY == 0 && !irq, "reset configuration/IRQ");
    read_check(REG_VERSION, 32'h53440100, "VERSION");
    // Table 5-1 gives STATUS and ERR a register each (0x08, 0x0C). They used
    // to share one word with CTRL, IRQ_EN and IRQ_STAT.
    read_check(REG_STATUS, 32'h0000_00a5, "STATUS");
    read_check(REG_ERR,    32'h0000_0005, "ERR");
    read_check(REG_CARD_BLK, 32'h12345678, "CARD_BLK");
    read_check(REG_STAT_RETRY, 32'h44556677, "STAT_RETRY");

    write_reg(REG_LBA, 32'h11223344, 4'b1111);
    write_reg(REG_LBA, 32'haa00cc00, 4'b0101);
    read_check(REG_LBA, 32'h11003300, "LBA byte strobes");

    // BLOCKS (0x14) and XFER (0x18) are separate registers.
    write_reg(REG_BLOCKS, 32'h00abcdef, 4'b1111);
    read_check(REG_BLOCKS, 32'h00abcdef, "BLOCKS write/read");
    // BLOCKS is 24 bits: the top byte reads back zero whatever was written.
    write_reg(REG_BLOCKS, 32'hff000000, 4'b1000);
    read_check(REG_BLOCKS, 32'h00abcdef, "BLOCKS ignores bits above 23");
    write_reg(REG_XFER, 32'(1 << XFER_DIR_BIT), 4'b0001);
    read_check(REG_XFER, 32'h0000_0001, "XFER write/read");

    // CFG_CLK (0x1C) and CFG_PHY (0x20) likewise. The separation matters:
    // while they shared a word, software setting a PHY force bit with an
    // ordinary 32-bit write zeroed the clock divisor.
    write_reg(REG_CFG_CLK, 32'h0000_0055, 4'b0001);
    write_reg(REG_CFG_PHY, 32'h0000_002d, 4'b0001);
    check(CFG_CLK == 8'h55 && CFG_PHY == 6'h2d, "configuration writes");
    read_check(REG_CFG_CLK, 32'h0000_0055, "CFG_CLK read");
    read_check(REG_CFG_PHY, 32'h0000_002d, "CFG_PHY read");

    // CFG_CLK is the only source of the SD clock divisor, so the init ladder
    // seeds it through CFG_CLK_HW rather than driving the PHY around the
    // register. Two things have to hold: a read of CFG_CLK always reports the
    // divisor actually in force, and a software write still wins.
    CFG_CLK_HW = 8'h04; @(posedge clk); #1;
    check(CFG_CLK == 8'h04, "init ladder seeds CFG_CLK");
    read_check(REG_CFG_CLK, 32'h0000_0004, "seeded CFG_CLK reads back");

    write_reg(REG_CFG_CLK, 32'h0000_0002, 4'b0001);
    check(CFG_CLK == 8'h02, "software overrides the seeded divisor");
    repeat (3) @(posedge clk); #1;
    check(CFG_CLK == 8'h02, "an unchanged ladder does not reclaim CFG_CLK");

    // Ladder change and software write in the same cycle: software wins.
    @(negedge clk); CFG_CLK_HW = 8'h10; wr_addr = REG_CFG_CLK;
    wr_data = 32'h0000_0008; wr_strb = 4'b0001; wr_en = 1;
    @(posedge clk); #1;
    check(CFG_CLK == 8'h08, "software write wins a simultaneous ladder load");
    @(negedge clk); wr_en = 0;

    // START snapshots LBA/BLOCKS/XFER and is a one-cycle pulse.
    write_reg(REG_CTRL, 1, 4'b0001);
    check(CTRL[CTRL_START_BIT], "START pulse asserted");
    check(LBA == 32'h11003300 && BLOCKS == 24'habcdef && XFER,
          "START snapshot");
    @(posedge clk); #1;
    check(CTRL == 0, "CTRL self clears");
    write_reg(REG_LBA, 32'hdeadbeef, 4'b1111);
    check(LBA == 32'h11003300, "active request snapshot is stable");

    // Read-only writes are ignored.
    write_reg(REG_CARD_BLK, 32'hffffffff, 4'b1111);
    read_check(REG_CARD_BLK, 32'h12345678, "RO write ignored");

    // Pending IRQ, enable, W1C, and set-wins-clear collision.
    IRQ_SET = 3'b010; @(posedge clk); #1; IRQ_SET = 0;
    write_reg(REG_IRQ_EN, 32'(3'b010 << IRQ_EN_LSB), 4'b0001);
    check(irq, "enabled pending IRQ raises pin");
    write_reg(REG_IRQ_STAT, 32'(3'b010 << IRQ_STAT_LSB), 4'b0001);
    check(!irq, "IRQ_STAT W1C clears pin");
    @(negedge clk); IRQ_SET = 3'b010; wr_addr = REG_IRQ_STAT;
    wr_data = 32'(3'b010 << IRQ_STAT_LSB); wr_strb = 4'b0001; wr_en = 1;
    @(posedge clk); #1;
    check(irq, "IRQ set wins simultaneous clear");
    @(negedge clk); IRQ_SET = 0; wr_en = 0;

    // Unmapped and out-of-window accesses must return SLVERR.
    // 0x40 is the first word above Table 5-1's last row (IRQ_STAT at 0x3C).
    @(negedge clk); rd_addr = 32'h00000040; rd_en = 1; #1;
    check(rresp_r == 2'b10, "unmapped read SLVERR");
    @(negedge clk); rd_en = 0;
    write_reg(32'h00000100, 0, 4'hf);
    check(bresp_r == 2'b10, "out-of-window write SLVERR");

    if (failures) begin
      $display("tb_ultra_sd_reg: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_ultra_sd_reg: PASSED (%0d checks)", checks);
    $finish;
  end
endmodule

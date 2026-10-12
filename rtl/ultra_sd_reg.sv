

module ultra_sd_reg
  import ultra_sd_pkg::*;
#(

  parameter logic [31:0] SD_ULTRA_BASE_ADDR = 32'h0000_0000,
  parameter logic [7:0]  VERSION_MAJOR      = 8'h01,
  parameter logic [7:0]  VERSION_MINOR      = 8'h00
) (
  input  logic                clk,
  input  logic                rst_n,

  input  logic                wr_en,
  input  logic [31:0]         wr_addr,
  input  logic [31:0]         wr_data,
  input  logic [3:0]          wr_strb,
  output logic [1:0]          bresp_r,

  input  logic                rd_en,
  input  logic [31:0]         rd_addr,
  output logic [31:0]         rd_data,
  output logic [1:0]          rresp_r,

  output logic [CTRL_W-1:0]    CTRL,

  output logic [LBA_W-1:0]     LBA,
  output logic [BLOCKS_W-1:0]  BLOCKS,
  output logic                 XFER,
  output logic [CFG_CLK_W-1:0] CFG_CLK,

  output logic [CFG_PHY_W-1:0] CFG_PHY,

  input  logic [STATUS_W-1:0]  STATUS,
  input  err_e                 ERR,
  input  logic [31:0]          CARD_BLK,
  input  logic [31:0]          STAT_DATA,
  input  logic [31:0]          STAT_GAP,
  input  logic [31:0]          STAT_BUSY,
  input  logic [31:0]          STAT_RETRY,

  input  logic [IRQ_W-1:0]     IRQ_SET,

  // The init ladder's own choice of divisor. CFG_CLK is the single source of
  // truth for the SD clock, so the ladder seeds it here rather than driving the
  // PHY behind the register's back -- that way a read of CFG_CLK always says
  // what the clock is actually doing, and a software write still wins.
  input  logic [CFG_CLK_W-1:0] CFG_CLK_HW,
  output logic                 irq
);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  /* verilator lint_off UNUSED */
  logic [31:0] wr_off, rd_off;
  /* verilator lint_on UNUSED */
  logic [3:0]  wr_reg, rd_reg;
  logic        wr_in_window, rd_in_window;
  logic        wr_mapped, rd_mapped;

  assign wr_off = wr_addr - SD_ULTRA_BASE_ADDR;
  assign rd_off = rd_addr - SD_ULTRA_BASE_ADDR;

  // DECODE ON FOUR BITS, NOT EIGHT.
  //
  // Table 5-1 occupies 0x00..0x3C with no holes, so the whole map is selected
  // by off[5:2] -- sixteen words -- and off[7:6] says whether the access is
  // inside the map at all. Comparing the full byte offset against sixteen
  // 8-bit constants, which is what this did, builds sixteen 8-input
  // comparators where sixteen 4-input ones will do.
  //
  // That is worth the paragraph because it is the difference between fitting
  // and not: giving every row of Table 5-1 its own register cost 148 LUT4
  // over the packed map it replaced and took the core to 2524, over the 2500
  // budget. Narrowing the decode gives most of it back, and it is a property
  // of the map rather than a trick -- the map is dense and 64 bytes long, so
  // two bits of address are known zero by construction.
  assign wr_reg = wr_off[5:2];
  assign rd_reg = rd_off[5:2];

  // In the 256-byte window at all (anything else is somebody else's slave)...
  assign wr_in_window = (wr_off[31:8] == '0);
  assign rd_in_window = (rd_off[31:8] == '0);

  // ...and inside the 64 bytes Table 5-1 actually defines. Section 5 reserves
  // everything above 0x3C for additions, and R-IF-2 says an access there
  // completes with SLVERR rather than hanging.
  assign wr_mapped = (wr_off[7:6] == 2'b00);
  assign rd_mapped = (rd_off[7:6] == 2'b00);

  logic [LBA_W-1:0]     lba_q;
  logic [BLOCKS_W-1:0]  blocks_q;
  logic                 xfer_q;
  logic [CFG_CLK_W-1:0] cfg_clk_q;
  logic [CFG_PHY_W-1:0] cfg_phy_q;
  logic [IRQ_W-1:0]     irq_en_q, irq_stat_q;

  // Quasi-static: the ladder moves it twice during init and never again, so a
  // change detector is enough and no handshake is needed.
  logic [CFG_CLK_W-1:0] cfg_clk_hw_q;

  assign CFG_CLK = cfg_clk_q;
  assign CFG_PHY = cfg_phy_q;

  assign irq = |(irq_stat_q & irq_en_q);

  logic        rd_hit;
  logic [31:0] stat_mux;

  always_comb begin
    case (rd_reg)
      REG_STAT_DATA[5:2]: stat_mux = STAT_DATA;
      REG_STAT_GAP[5:2]:  stat_mux = STAT_GAP;
      REG_STAT_BUSY[5:2]: stat_mux = STAT_BUSY;
      default:            stat_mux = STAT_RETRY;
    endcase
  end

  // One row of Table 5-1 per case arm. CTRL reads back what was last written
  // to it even though it is W1S and self-clearing, because a write-only
  // register that answers an unmapped-looking read is harder to drive from
  // software than one that answers zero.
  always_comb begin
    rd_data = 32'h0;
    rd_hit  = 1'b1;
    unique case (rd_reg)
      REG_VERSION[5:2]:    rd_data = {VERSION_MAGIC, VERSION_MAJOR, VERSION_MINOR};
      REG_CTRL[5:2]:       rd_data = {28'h0, CTRL};
      REG_STATUS[5:2]:     rd_data = {24'h0, STATUS};
      REG_ERR[5:2]:        rd_data = {24'h0, ERR};
      REG_LBA[5:2]:        rd_data = lba_q;
      REG_BLOCKS[5:2]:     rd_data = {8'h0, blocks_q};
      REG_XFER[5:2]:       rd_data = {31'h0, xfer_q};
      REG_CFG_CLK[5:2]:    rd_data = {24'h0, cfg_clk_q};
      REG_CFG_PHY[5:2]:    rd_data = {26'h0, cfg_phy_q};
      REG_CARD_BLK[5:2]:   rd_data = CARD_BLK;
      REG_STAT_DATA[5:2],
      REG_STAT_GAP[5:2],
      REG_STAT_BUSY[5:2],
      REG_STAT_RETRY[5:2]: rd_data = stat_mux;
      REG_IRQ_EN[5:2]:     rd_data = {29'h0, irq_en_q};
      REG_IRQ_STAT[5:2]:   rd_data = {29'h0, irq_stat_q};
      default:             rd_hit  = 1'b0;
    endcase
  end

  assign rresp_r = (rd_en && !(rd_hit && rd_mapped && rd_in_window)) ? RESP_SLVERR
                                                                    : RESP_OKAY;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bresp_r    <= RESP_OKAY;
      CTRL       <= '0;
      LBA        <= '0;
      BLOCKS     <= BLOCKS_W'(1);
      XFER       <= 1'b0;
      lba_q      <= '0;
      blocks_q   <= BLOCKS_W'(1);
      xfer_q     <= 1'b0;
      cfg_clk_q    <= '1;
      cfg_clk_hw_q <= '1;
      cfg_phy_q    <= '0;
      irq_en_q   <= '0;
      irq_stat_q <= '0;
    end else begin

      CTRL <= '0;

      // Before the write case, so that a software write in the same cycle is
      // the later assignment and therefore the one that sticks.
      cfg_clk_hw_q <= CFG_CLK_HW;
      if (cfg_clk_hw_q != CFG_CLK_HW) cfg_clk_q <= CFG_CLK_HW;

      if (wr_en) begin
        bresp_r <= (wr_in_window && wr_mapped) ? RESP_OKAY : RESP_SLVERR;

        unique case (wr_reg)
          REG_CTRL[5:2]: begin
            if (wr_strb[0]) begin
              CTRL <= wr_data[CTRL_W-1:0];

              // R-IF-3: LBA, BLOCKS and XFER are latched AT THE START WRITE,
              // so changing them mid-transfer cannot affect the one running.
              if (wr_data[CTRL_START_BIT]) begin
                LBA    <= lba_q;
                BLOCKS <= blocks_q;
                XFER   <= xfer_q;
              end
            end
          end

          REG_LBA[5:2]: begin
            if (wr_strb[0]) lba_q[7:0]   <= wr_data[7:0];
            if (wr_strb[1]) lba_q[15:8]  <= wr_data[15:8];
            if (wr_strb[2]) lba_q[23:16] <= wr_data[23:16];
            if (wr_strb[3]) lba_q[31:24] <= wr_data[31:24];
          end

          REG_BLOCKS[5:2]: begin
            if (wr_strb[0]) blocks_q[7:0]   <= wr_data[7:0];
            if (wr_strb[1]) blocks_q[15:8]  <= wr_data[15:8];
            if (wr_strb[2]) blocks_q[23:16] <= wr_data[23:16];
          end

          REG_XFER[5:2]: begin
            if (wr_strb[0]) xfer_q <= wr_data[XFER_DIR_BIT];
          end

          REG_CFG_CLK[5:2]: begin
            if (wr_strb[0]) cfg_clk_q <= wr_data[CFG_CLK_LSB +: CFG_CLK_W];
          end

          REG_CFG_PHY[5:2]: begin
            if (wr_strb[0]) cfg_phy_q <= wr_data[CFG_PHY_LSB +: CFG_PHY_W];
          end

          REG_IRQ_EN[5:2]: begin
            if (wr_strb[0]) irq_en_q <= wr_data[IRQ_EN_LSB +: IRQ_W];
          end

          // IRQ_STAT is W1C and handled below, outside the case, because the
          // set side (IRQ_SET) has to win over the clear in the same cycle.
          REG_IRQ_STAT[5:2]: ;

          REG_VERSION[5:2], REG_STATUS[5:2], REG_ERR[5:2], REG_CARD_BLK[5:2],
          REG_STAT_DATA[5:2], REG_STAT_GAP[5:2], REG_STAT_BUSY[5:2],
          REG_STAT_RETRY[5:2]: ;

          default: bresp_r <= RESP_SLVERR;
        endcase
      end

      for (int i = 0; i < IRQ_W; i++) begin
        logic clr_i;
        clr_i = wr_en && wr_mapped && (wr_reg == REG_IRQ_STAT[5:2]) && wr_strb[0] &&
                wr_data[IRQ_STAT_LSB + i];
        if (IRQ_SET[i])  irq_stat_q[i] <= 1'b1;
        else if (clr_i)  irq_stat_q[i] <= 1'b0;
      end
    end
  end

endmodule

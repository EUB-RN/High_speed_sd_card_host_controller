

module ultra_sd_axi_top
  import ultra_sd_pkg::*;
#(
  parameter int DATA_W             = 32,
  parameter int ADDR_W             = 8,
  parameter int RD_FIFO_BLOCKS     = 2,
  parameter int WR_FIFO_BLOCKS     = 2,

  parameter logic [31:0] SD_ULTRA_BASE_ADDR = 32'h0000_0000
) (

  input  logic              clk,
  input  logic              rst_n,

  input  logic              sd_clk,
  input  logic              sd_rst_n,

  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,

  output logic [DATA_W-1:0] m_axis_rd_tdata,
  output logic              m_axis_rd_tvalid,
  input  logic              m_axis_rd_tready,
  output logic              m_axis_rd_tlast,

  input  logic [DATA_W-1:0] s_axis_wr_tdata,
  input  logic              s_axis_wr_tvalid,
  output logic              s_axis_wr_tready,
  input  logic              s_axis_wr_tlast,

  output logic              irq,

  output logic [CTRL_W-1:0]    CTRL,

  output logic [LBA_W-1:0]     LBA,
  output logic [BLOCKS_W-1:0]  BLOCKS,
  output logic                 XFER,
  output logic [CFG_CLK_W-1:0] CFG_CLK,
  input  logic [CFG_CLK_W-1:0] CFG_CLK_HW,
  output logic [CFG_PHY_W-1:0] CFG_PHY,
  output logic                 rd_xfer_busy,

  input  logic [STATUS_W-1:0]  STATUS,
  input  err_e                 ERR,
  input  logic [31:0]          CARD_BLK,
  input  logic [31:0]          STAT_DATA,
  input  logic [31:0]          STAT_GAP,
  input  logic [31:0]          STAT_BUSY,
  input  logic [31:0]          STAT_RETRY,
  input  logic [IRQ_W-1:0]     IRQ_SET,

  input  logic              sd_rd_pl_en,
  input  logic [DATA_W-1:0] sd_rd_pl_data,
  input  logic              sd_rd_pl_commit,
  input  logic              sd_rd_pl_rewind,
  output logic              sd_rd_pl_full,
  output logic              sd_rd_pl_block_room,
  output logic [$clog2(RD_FIFO_BLOCKS*((512*8)/DATA_W)):0] sd_rd_pl_level,

  input  logic              sd_wr_pl_en,
  input  logic              sd_wr_pl_commit,
  input  logic              sd_wr_pl_rewind,
  output logic [DATA_W-1:0] sd_wr_pl_data,
  output logic              sd_wr_pl_last,
  output logic              sd_wr_pl_valid,
  output logic [$clog2(WR_FIFO_BLOCKS*((512*8)/DATA_W)):0] sd_wr_pl_level,
  output logic              sd_wr_pl_block_ready
);

  localparam int BEATS_PER_BLOCK = (512 * 8) / DATA_W;
  localparam int RD_FIFO_WORDS   = RD_FIFO_BLOCKS * BEATS_PER_BLOCK;
  localparam int WR_FIFO_WORDS   = WR_FIFO_BLOCKS * BEATS_PER_BLOCK;

  logic              bus_wr_en;
  logic [ADDR_W-1:0] bus_wr_addr;
  logic [31:0]       bus_wr_data;
  logic [3:0]        bus_wr_strb;
  logic [1:0]        bus_bresp;

  logic              bus_rd_en;
  logic [ADDR_W-1:0] bus_rd_addr;
  logic [31:0]       bus_rd_data;
  logic [1:0]        bus_rresp;

  axi4_lite_slave #(
    .ADDR_WIDTH (ADDR_W),
    .DATA_WIDTH (32),
    .BASE_ADDR  (SD_ULTRA_BASE_ADDR),
    .HIGH_ADDR  (SD_ULTRA_BASE_ADDR + 32'd255)
  ) u_axil (
    .clk      (clk),
    .reset_n  (rst_n),
    .AWADDR   (s_axil_awaddr),
    .AWVALID  (s_axil_awvalid),
    .AWREADY  (s_axil_awready),
    .WDATA    (s_axil_wdata),
    .WSTRB    (s_axil_wstrb),
    .WVALID   (s_axil_wvalid),
    .WREADY   (s_axil_wready),
    .BRESP    (s_axil_bresp),
    .BVALID   (s_axil_bvalid),
    .BREADY   (s_axil_bready),
    .ARADDR   (s_axil_araddr),
    .ARVALID  (s_axil_arvalid),
    .ARREADY  (s_axil_arready),
    .RDATA    (s_axil_rdata),
    .RRESP    (s_axil_rresp),
    .RVALID   (s_axil_rvalid),
    .RREADY   (s_axil_rready),
    .wr_en    (bus_wr_en),
    .wr_addr  (bus_wr_addr),
    .wr_data  (bus_wr_data),
    .wr_strb  (bus_wr_strb),
    .rd_en    (bus_rd_en),
    .rd_addr  (bus_rd_addr),
    .rd_data  (bus_rd_data),
    .bresp_r  (bus_bresp),
    .rresp_r  (bus_rresp)
  );

  ultra_sd_reg #(
    .SD_ULTRA_BASE_ADDR (SD_ULTRA_BASE_ADDR)
  ) u_reg (
    .clk                 (clk),
    .rst_n               (rst_n),
    .wr_en               (bus_wr_en),
    .wr_addr             ({{(32-ADDR_W){1'b0}}, bus_wr_addr}),
    .wr_data             (bus_wr_data),
    .wr_strb             (bus_wr_strb),
    .bresp_r             (bus_bresp),
    .rd_en               (bus_rd_en),
    .rd_addr             ({{(32-ADDR_W){1'b0}}, bus_rd_addr}),
    .rd_data             (bus_rd_data),
    .rresp_r             (bus_rresp),
    .CTRL                (CTRL),
    .LBA                 (LBA),
    .BLOCKS              (BLOCKS),
    .XFER                (XFER),
    .CFG_CLK             (CFG_CLK),
    .CFG_CLK_HW          (CFG_CLK_HW),
    .CFG_PHY             (CFG_PHY),
    .STATUS              (STATUS),
    .ERR                 (ERR),
    .CARD_BLK            (CARD_BLK),
    .STAT_DATA           (STAT_DATA),
    .STAT_GAP            (STAT_GAP),
    .STAT_BUSY           (STAT_BUSY),
    .STAT_RETRY          (STAT_RETRY),
    .IRQ_SET             (IRQ_SET),
    .irq                 (irq)
  );

  logic        rd_start;
  logic [31:0] rd_beats;

  assign rd_start = CTRL[CTRL_START_BIT] && !XFER;
  assign rd_beats = 32'(BLOCKS) * 32'(BEATS_PER_BLOCK);

  axis_rd_master #(
    .DATA_W     (DATA_W),
    .FIFO_DEPTH (RD_FIFO_WORDS)
  ) u_axis_tx (
    .axi_clk          (clk),
    .axi_rst_n        (rst_n),
    .xfer_start       (rd_start),
    .xfer_beats       (rd_beats),
    .xfer_abort       (CTRL[CTRL_ABORT_BIT]),
    .xfer_busy        (rd_xfer_busy),
    .m_axis_rd_tdata  (m_axis_rd_tdata),
    .m_axis_rd_tvalid (m_axis_rd_tvalid),
    .m_axis_rd_tready (m_axis_rd_tready),
    .m_axis_rd_tlast  (m_axis_rd_tlast),
    .sd_clk           (sd_clk),
    .sd_rst_n         (sd_rst_n),
    .sd_wr_en         (sd_rd_pl_en),
    .sd_wr_data       (sd_rd_pl_data),
    .sd_wr_commit     (sd_rd_pl_commit),
    .sd_wr_rewind     (sd_rd_pl_rewind),
    .sd_wr_full       (sd_rd_pl_full),
    .sd_wr_block_room (sd_rd_pl_block_room),
    .sd_wr_level      (sd_rd_pl_level)
  );

  axis_wr_slave #(
    .DATA_W     (DATA_W),
    .FIFO_DEPTH (WR_FIFO_WORDS)
  ) u_axis_rx (
    .axi_clk          (clk),
    .axi_rst_n        (rst_n),
    .s_axis_wr_tdata  (s_axis_wr_tdata),
    .s_axis_wr_tvalid (s_axis_wr_tvalid),
    .s_axis_wr_tready (s_axis_wr_tready),
    .s_axis_wr_tlast  (s_axis_wr_tlast),
    .sd_clk           (sd_clk),
    .sd_rst_n         (sd_rst_n),
    .sd_rd_en         (sd_wr_pl_en),
    .sd_rd_commit     (sd_wr_pl_commit),
    .sd_rd_rewind     (sd_wr_pl_rewind),
    .sd_rd_data       (sd_wr_pl_data),
    .sd_rd_last       (sd_wr_pl_last),
    .sd_rd_valid      (sd_wr_pl_valid),
    .sd_rd_level      (sd_wr_pl_level),
    .sd_block_ready   (sd_wr_pl_block_ready)
  );

endmodule

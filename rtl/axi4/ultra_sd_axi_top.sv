// -----------------------------------------------------------------------------
// ultra_sd_axi_top
//   Purpose      : L4. The complete host-facing layer: the AXI4-Lite slave and
//                  the Table 5-1 register file, the AXI4-Stream transmitter
//                  (read payload, card -> host) and receiver (write payload,
//                  host -> card), and the two dual-clock FIFOs that carry
//                  payload between the AXI and SD clock domains. Wiring and
//                  request bookkeeping only -- no SD protocol knowledge and no
//                  command opcodes (Table 4-1).
//
//                  Layer boundary: everything above this module runs on clk,
//                  everything the block layer sees runs on sd_clk, and the only
//                  paths between them are the two async FIFOs instantiated here
//                  plus the status/counter inputs, which their producers
//                  synchronise (doc/cdc.md).
//
//   Clock domain : two. clk is the system clock; sd_clk is the divided SD clock
//                  from the PHY. The ratio changes at runtime with CFG_CLK, so
//                  nothing here may assume one (R-DEG-1).
//   Reset scheme : rst_n / sd_rst_n, async assert / sync deassert (R-CLK-1)
//   Implements   : Spec Section 5.3, 5.4, R-IF-1 .. R-IF-12
// -----------------------------------------------------------------------------
module ultra_sd_axi_top
  import ultra_sd_pkg::*;
#(
  parameter int unsigned DATA_W             = 32,
  parameter int unsigned ADDR_W             = 8,
  parameter int unsigned RD_FIFO_BLOCKS     = 2,
  parameter int unsigned WR_FIFO_BLOCKS     = 2,
  // Byte address of VERSION. Stays 0 while the AXI address port is the 8 bits
  // of Figure 5-1; it exists for instantiations behind a wider host bus.
  parameter logic [31:0] SD_ULTRA_BASE_ADDR = 32'h0000_0000
) (
  // ---- system / AXI domain -------------------------------------------------
  input  logic              clk,
  input  logic              rst_n,

  // ---- SD domain, from the PHY divider -------------------------------------
  input  logic              sd_clk,
  input  logic              sd_rst_n,

  // ---- AXI4-Lite slave: control and status (Figure 5-1) --------------------
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

  // ---- AXI4-Stream master: read payload, card -> host ----------------------
  output logic [DATA_W-1:0] m_axis_rd_tdata,
  output logic              m_axis_rd_tvalid,
  input  logic              m_axis_rd_tready,
  output logic              m_axis_rd_tlast,

  // ---- AXI4-Stream slave: write payload, host -> card ----------------------
  input  logic [DATA_W-1:0] s_axis_wr_tdata,
  input  logic              s_axis_wr_tvalid,
  output logic              s_axis_wr_tready,
  input  logic              s_axis_wr_tlast,

  output logic              irq,

  // ---- to the block layer: request and configuration (clk domain) ----------
  // UPPER_CASE = one CPU-visible register of Table 5-1, packed exactly as the
  // table specifies; field positions are named in ultra_sd_pkg. The convention
  // is explained in the header of ultra_sd_reg.sv.
  output logic [CTRL_W-1:0]    CTRL,     // [0] START [1] ABORT [2] STAT_CLEAR
                                         // [3] SOFT_RESET -- one-cycle pulses
  output logic [LBA_W-1:0]     LBA,      // latched at CTRL.START (R-IF-3)
  output logic [BLOCKS_W-1:0]  BLOCKS,
  output logic                 XFER,     // [0] DIR: 0 = read, 1 = write
  output logic [CFG_CLK_W-1:0] CFG_CLK,
  output logic [CFG_PHY_W-1:0] CFG_PHY,
  output logic                 rd_xfer_busy, // stream still owes beats

  // ---- from the block layer: status and counters (clk domain) --------------
  input  logic [STATUS_W-1:0]  STATUS,
  input  err_e                 ERR,
  input  logic [31:0]          CARD_BLK,
  input  logic [31:0]          STAT_DATA,
  input  logic [31:0]          STAT_GAP,
  input  logic [31:0]          STAT_BUSY,
  input  logic [31:0]          STAT_RETRY,
  input  logic [IRQ_W-1:0]     IRQ_SET,

  // ---- read payload in from the block layer (sd_clk domain) ----------------
  input  logic              sd_rd_pl_en,
  input  logic [DATA_W-1:0] sd_rd_pl_data,
  output logic              sd_rd_pl_full,
  output logic [$clog2(RD_FIFO_BLOCKS*((512*8)/DATA_W)):0] sd_rd_pl_level,

  // ---- write payload out to the block layer (sd_clk domain) ----------------
  input  logic              sd_wr_pl_en,
  output logic [DATA_W-1:0] sd_wr_pl_data,
  output logic              sd_wr_pl_last,
  output logic              sd_wr_pl_valid,
  output logic [$clog2(WR_FIFO_BLOCKS*((512*8)/DATA_W)):0] sd_wr_pl_level,
  output logic              sd_wr_pl_block_ready
);

  // 512-byte blocks, Table 5-1. Both FIFO depths must come out a power of two.
  localparam int unsigned BEATS_PER_BLOCK = (512 * 8) / DATA_W;
  localparam int unsigned RD_FIFO_WORDS   = RD_FIFO_BLOCKS * BEATS_PER_BLOCK;
  localparam int unsigned WR_FIFO_WORDS   = WR_FIFO_BLOCKS * BEATS_PER_BLOCK;

  // ---------------------------------------------------------------------------
  // AXI4-Lite slave -> register file
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // AXI4-Stream transmitter: read payload, card -> host
  //
  // The beat count for the whole request is derived from the BLOCKS value the
  // register file latched at CTRL.START (R-IF-3), so tlast belongs to the
  // request and not to whatever the card happens to deliver (R-IF-6).
  // ---------------------------------------------------------------------------
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
    .sd_wr_full       (sd_rd_pl_full),
    .sd_wr_level      (sd_rd_pl_level)
  );

  // ---------------------------------------------------------------------------
  // AXI4-Stream receiver: write payload, host -> card
  // ---------------------------------------------------------------------------
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
    .sd_rd_data       (sd_wr_pl_data),
    .sd_rd_last       (sd_wr_pl_last),
    .sd_rd_valid      (sd_wr_pl_valid),
    .sd_rd_level      (sd_wr_pl_level),
    .sd_block_ready   (sd_wr_pl_block_ready)
  );

endmodule

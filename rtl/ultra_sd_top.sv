// -----------------------------------------------------------------------------
// ultra_sd_top
//   Purpose      : Integration wrapper. SD pad instantiation via the PHY, AXI
//                  ports out to the harness. Wiring only -- no logic beyond
//                  module instances is permitted here (R-ARCH-1, Table 4-1).
//   Clock domain : clk (system clock, SYS_CLK_HZ)
//   Reset scheme : rst_n, asynchronous assert / synchronous deassert (R-CLK-1)
//   Implements   : Spec Section 5.2 (normative port list, Figure 5-1)
//   Note         : The port list below is normative and exact. The harness
//                  instantiates this module and nothing else (Figure 4-1).
// -----------------------------------------------------------------------------
module ultra_sd_top #(
  parameter int unsigned SYS_CLK_HZ     = 100_000_000, // supplied by harness
  parameter int unsigned DATA_W         = 32,          // AXIS payload width
  parameter int unsigned RD_FIFO_BLOCKS = 2,
  parameter int unsigned WR_FIFO_BLOCKS = 2,
  parameter int unsigned CRC_RETRIES    = 3
) (
  input  logic              clk,            // system clock, SYS_CLK_HZ
  input  logic              rst_n,          // async assert, sync deassert

  // ---- AXI4-Lite slave: control and status ---------------------------------
  input  logic [7:0]        s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [7:0]        s_axil_araddr,
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
  output logic              m_axis_rd_tlast, // last beat of the request

  // ---- AXI4-Stream slave: write payload, host -> card ----------------------
  input  logic [DATA_W-1:0] s_axis_wr_tdata,
  input  logic              s_axis_wr_tvalid,
  output logic              s_axis_wr_tready,
  input  logic              s_axis_wr_tlast,

  // ---- interrupt -----------------------------------------------------------
  output logic              irq,            // level, cleared via IRQ_STAT

  // ---- SD card pads --------------------------------------------------------
  output logic              sd_clk,
  inout  wire               sd_cmd,
  inout  wire  [3:0]        sd_dat,
  input  logic              sd_cd           // ACTIVE LOW: 0 = present
);

  // TODO: instantiate ultra_sd_core (same signals, with the two inout pad ports
  // replaced by explicit output / output-enable / input triples) and the pad
  // tristate control inside ultra_sd_phy_gowin -- see Figure 5-1 note.

endmodule

// -----------------------------------------------------------------------------
// vip_axi_top
//   Purpose      : Harness for the cocotbext-axi verification IP. Wraps the
//                  real delivered host interface, ultra_sd_axi_top, and
//                  presents nothing but plain logic at its boundary -- no
//                  package types, no enums -- because the VIP binds to signal
//                  names from Python and must not have to know about
//                  ultra_sd_pkg.
//
//                  The block layer below the AXI layer is still a stub, so
//                  this harness supplies the two things the AXI layer needs
//                  from it to be exercisable at all:
//
//                    sd_feed_en   an SD-domain producer that fills the read
//                                 payload FIFO with a counting pattern, so
//                                 the read stream has something to stream
//                    sd_drain_en  an SD-domain consumer that empties the
//                                 write payload FIFO, so the write stream can
//                                 make progress -- and which, held low,
//                                 produces exactly the backpressure R-IF-7
//                                 asks about
//
//                  The counting pattern is what makes the read path
//                  data-checkable from Python: beat n of the transfer must
//                  carry n. Nothing here models the SD protocol.
//
//   Clock domain : two, as in the DUT. clk is the AXI domain, sd_clk the SD
//                  domain; the VIP only ever touches the AXI domain.
//   Covers       : the harness for R-IF-1, R-IF-2, R-IF-5 .. R-IF-8
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module vip_axi_top
  import ultra_sd_pkg::*;
#(
  parameter int DATA_W         = 32,
  parameter int ADDR_W         = 8,
  parameter int RD_FIFO_BLOCKS = 2,
  parameter int WR_FIFO_BLOCKS = 2
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              sd_clk,
  input  logic              sd_rst_n,

  // ---- AXI4-Lite slave, the names cocotbext-axi binds to -------------------
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

  // ---- stand-in block layer, driven from the test --------------------------
  input  logic              sd_feed_en,
  input  logic              sd_drain_en,

  // One cycle high resets every monitor's counters. The cocotb test pulses it
  // after reset release so that the transaction counts cover the stimulus
  // only, and between scenarios in a multi-part test.
  input  logic              mon_clear,

  // Expected beats per AXI4-Stream packet on each side, 0 to disable the
  // framing check. Set by the test from the transfer it asked for.
  input  logic [31:0]       rd_pkt_beats,
  input  logic [31:0]       wr_pkt_beats,

  // ---- observability -------------------------------------------------------
  output logic              rd_xfer_busy,
  output logic [31:0]       sd_drained_count,  // beats taken off the write FIFO
  output logic [DATA_W-1:0] sd_drained_last_data,
  output logic              sd_saw_pl_last     // sticky: a tlast reached the SD side
);

  // ---- transfer launch, standing in for system_controller --------------------
  logic [ultra_sd_pkg::CTRL_W-1:0] ctrl_w;
  logic                            ctrl_start_q;
  logic                            xfer_launch;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ctrl_start_q <= 1'b0;
    else        ctrl_start_q <= ctrl_w[ultra_sd_pkg::CTRL_START_BIT];
  end

  // Rising edge only: CTRL holds its written value, so a level would re-launch
  // the engine on every cycle after the first.
  assign xfer_launch = ctrl_w[ultra_sd_pkg::CTRL_START_BIT] && !ctrl_start_q;

  // ---- SD-domain producer for the read path ---------------------------------
  logic              sd_rd_pl_en;
  logic [DATA_W-1:0] sd_rd_pl_data;
  logic              sd_rd_pl_full;

  logic [DATA_W-1:0] feed_count;

  always_ff @(posedge sd_clk or negedge sd_rst_n) begin
    if (!sd_rst_n) begin
      feed_count  <= '0;
      sd_rd_pl_en <= 1'b0;
    end else begin
      sd_rd_pl_en <= sd_feed_en && !sd_rd_pl_full;
      if (sd_feed_en && !sd_rd_pl_full) feed_count <= feed_count + 1;
    end
  end

  // sd_rd_pl_en is registered, so the data must be the value that was current
  // when the enable was decided, not the one after the increment.
  logic [DATA_W-1:0] feed_count_q;
  always_ff @(posedge sd_clk or negedge sd_rst_n) begin
    if (!sd_rst_n) feed_count_q <= '0;
    else           feed_count_q <= feed_count;
  end
  assign sd_rd_pl_data = feed_count_q;

  // ---- SD-domain consumer for the write path --------------------------------
  logic              sd_wr_pl_en;
  logic [DATA_W-1:0] sd_wr_pl_data;
  logic              sd_wr_pl_last;
  logic              sd_wr_pl_valid;

  assign sd_wr_pl_en = sd_drain_en && sd_wr_pl_valid;

  always_ff @(posedge sd_clk or negedge sd_rst_n) begin
    if (!sd_rst_n) begin
      sd_drained_count     <= '0;
      sd_drained_last_data <= '0;
      sd_saw_pl_last       <= 1'b0;
    end else if (sd_wr_pl_en) begin
      sd_drained_count     <= sd_drained_count + 1;
      sd_drained_last_data <= sd_wr_pl_data;
      if (sd_wr_pl_last) sd_saw_pl_last <= 1'b1;
    end
  end

  // ---- the DUT --------------------------------------------------------------
  ultra_sd_axi_top #(
    .DATA_W         (DATA_W),
    .ADDR_W         (ADDR_W),
    .RD_FIFO_BLOCKS (RD_FIFO_BLOCKS),
    .WR_FIFO_BLOCKS (WR_FIFO_BLOCKS)
  ) dut (
    .clk              (clk),
    .rst_n            (rst_n),
    .sd_clk           (sd_clk),
    .sd_rst_n         (sd_rst_n),
    // Yazilim clear'i bu VIP'in konusu degil: iki alanda da sabit 0.
    .sd_soft_clr      (1'b0),
    .axi_soft_clr     (1'b0),

    .s_axil_awaddr    (s_axil_awaddr),
    .s_axil_awvalid   (s_axil_awvalid),
    .s_axil_awready   (s_axil_awready),
    .s_axil_wdata     (s_axil_wdata),
    .s_axil_wstrb     (s_axil_wstrb),
    .s_axil_wvalid    (s_axil_wvalid),
    .s_axil_wready    (s_axil_wready),
    .s_axil_bresp     (s_axil_bresp),
    .s_axil_bvalid    (s_axil_bvalid),
    .s_axil_bready    (s_axil_bready),
    .s_axil_araddr    (s_axil_araddr),
    .s_axil_arvalid   (s_axil_arvalid),
    .s_axil_arready   (s_axil_arready),
    .s_axil_rdata     (s_axil_rdata),
    .s_axil_rresp     (s_axil_rresp),
    .s_axil_rvalid    (s_axil_rvalid),
    .s_axil_rready    (s_axil_rready),

    .m_axis_rd_tdata  (m_axis_rd_tdata),
    .m_axis_rd_tvalid (m_axis_rd_tvalid),
    .m_axis_rd_tready (m_axis_rd_tready),
    .m_axis_rd_tlast  (m_axis_rd_tlast),

    .s_axis_wr_tdata  (s_axis_wr_tdata),
    .s_axis_wr_tvalid (s_axis_wr_tvalid),
    .s_axis_wr_tready (s_axis_wr_tready),
    .s_axis_wr_tlast  (s_axis_wr_tlast),

    .irq              (irq),

    // THE READ STREAM NEEDS A LAUNCH PULSE AND NOTHING WAS GIVING IT ONE.
    //
    // ultra_sd_axi_top builds the read engine's start from
    //   rd_start = xfer_launch && !XFER
    // and xfer_launch is an INPUT: in the real design system_controller raises
    // it for one cycle as it enters SYS_READ / SYS_WRITE. This harness has no
    // system_controller -- the block layer is a stub -- and it was leaving the
    // port unconnected, so rd_start was never asserted, beats_left_q stayed
    // zero, xfer_busy stayed low and m_axis_rd_tvalid could never rise.
    //
    // That is why test_read_stream_no_backpressure and
    // test_read_stream_backpressure timed out waiting for a frame while all
    // ten other cocotb tests passed: the two write-stream tests do not go
    // through this port, and the eight AXI-Lite tests never start a transfer.
    // The RTL was never involved.
    //
    // CTRL.START is the right stand-in. The register file latches LBA/BLOCKS/
    // XFER on the same write (R-IF-3), so a pulse derived from it carries
    // exactly the ordering ultra_sd_axi_top expects, and ctrl_q below makes it
    // one cycle wide the way system_controller's would be.
    .xfer_launch      (xfer_launch),

    // Register-file outputs. CTRL is observed now -- see above.
    .CTRL             (ctrl_w),
    .LBA              (),
    .BLOCKS           (),
    .XFER             (),
    .CFG_CLK          (),
    // Held at the register's own reset value: this harness exercises the bus,
    // not the init ladder, so the hardware-load path must never fire and
    // overwrite what a test just wrote.
    .CFG_CLK_HW       (8'hff),
    .CFG_PHY          (),
    .rd_xfer_busy     (rd_xfer_busy),

    // The block layer is a stub: it reports nothing, so the status inputs are
    // constants. The register file's read-back of them is still checkable --
    // a constant is a known value.
    // Explicit widths, not '0: Icarus treats an unsized literal in a port
    // connection as one bit and pads it, which is a warning per port.
    .STATUS           (8'h00),
    .ERR              (8'h00),   // ERR_OK
    .CARD_BLK         (32'd0),
    .STAT_DATA        (32'd0),
    .STAT_GAP         (32'd0),
    .STAT_BUSY        (32'd0),
    .STAT_RETRY       (32'd0),
    .IRQ_SET          (3'b000),

    .sd_rd_pl_en      (sd_rd_pl_en),
    .sd_rd_pl_data    (sd_rd_pl_data),
    // Bu VIP akis protokolunu sinar, blok spekulasyonunu degil: her kelime
    // yazildigi gibi yayinlanir (commit surekli yukari, geri sarma yok).
    // Blok granulerligini ultra_sd_block kullanir.
    .sd_rd_pl_commit  (1'b1),
    .sd_rd_pl_rewind  (1'b0),
    .sd_rd_pl_full    (sd_rd_pl_full),
    .sd_rd_pl_block_room (),
    .sd_rd_pl_level   (),

    .sd_wr_pl_en      (sd_wr_pl_en),
    .sd_wr_pl_commit  (1'b1),
    .sd_wr_pl_rewind  (1'b0),
    .sd_wr_pl_data    (sd_wr_pl_data),
    .sd_wr_pl_last    (sd_wr_pl_last),
    .sd_wr_pl_valid   (sd_wr_pl_valid),
    .sd_wr_pl_level   (),
    .sd_wr_pl_block_ready ()
  );

  // Our own SV monitors, bound to the same buses the Python VIP watches. They
  // are the always-on, Python-free checkers used by the other categories; here
  // they run alongside cocotbext-axi so the two can be compared on identical
  // traffic. That cross-check is what justifies trusting them elsewhere.
  axi4_lite_monitor #(
    .ADDR_W (ADDR_W),
    .DATA_W (32),
    .NAME   ("sv.axil")
  ) mon_axil (
    .clk (clk), .rst_n (rst_n), .clear_i (mon_clear),
    .awaddr (s_axil_awaddr), .awvalid (s_axil_awvalid), .awready (s_axil_awready),
    .wdata  (s_axil_wdata),  .wstrb   (s_axil_wstrb),
    .wvalid (s_axil_wvalid), .wready  (s_axil_wready),
    .bresp  (s_axil_bresp),  .bvalid  (s_axil_bvalid), .bready (s_axil_bready),
    .araddr (s_axil_araddr), .arvalid (s_axil_arvalid), .arready (s_axil_arready),
    .rdata  (s_axil_rdata),  .rresp   (s_axil_rresp),
    .rvalid (s_axil_rvalid), .rready  (s_axil_rready)
  );

  axis_monitor #(
    .DATA_W    (DATA_W),
    .NAME      ("sv.axis_rd")
  ) mon_axis_rd (
    .clk (clk), .rst_n (rst_n), .clear_i (mon_clear),
    .pkt_beats_i (rd_pkt_beats),
    .tdata (m_axis_rd_tdata), .tvalid (m_axis_rd_tvalid),
    .tready (m_axis_rd_tready), .tlast (m_axis_rd_tlast)
  );

  axis_monitor #(
    .DATA_W    (DATA_W),
    .NAME      ("sv.axis_wr")
  ) mon_axis_wr (
    .clk (clk), .rst_n (rst_n), .clear_i (mon_clear),
    .pkt_beats_i (wr_pkt_beats),
    .tdata (s_axis_wr_tdata), .tvalid (s_axis_wr_tvalid),
    .tready (s_axis_wr_tready), .tlast (s_axis_wr_tlast)
  );

endmodule

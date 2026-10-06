// -----------------------------------------------------------------------------
// axis_wr_slave
//   Purpose      : AXI4-Stream slave for the write payload, host -> card. The
//                  AXI side accepts stream beats at the system clock, the SD
//                  side pops them at the SD clock, and the async_fifo between
//                  the two is the documented crossing.
//
//                  sd_block_ready is the mechanism behind R-IF-8: it is high
//                  only when a whole 512-byte block is already buffered, so the
//                  block layer can refuse to start a block it would be unable
//                  to finish if the host producer stalls mid-block. The card
//                  cannot be paused in the middle of a data block, so this test
//                  is made before CMD24/CMD25 is issued and not during it.
//
//                  tlast travels with its word through the FIFO, so the SD side
//                  can tell where the host thinks the payload ends and raise
//                  ERR_PROTOCOL on a mismatch with BLOCKS.
//
//   Clock domain : two. axi_clk carries the stream; sd_clk carries the payload
//                  output. They are unrelated.
//   Reset scheme : axi_rst_n / sd_rst_n, async assert / sync deassert (R-CLK-1)
//   Implements   : R-IF-5, R-IF-8, R-CLK-3
// -----------------------------------------------------------------------------
module axis_wr_slave #(
  parameter int DATA_W     = 32,
  parameter int FIFO_DEPTH = 1024
) (
  // ---- AXI / system domain -------------------------------------------------
  input  logic                         axi_clk,
  input  logic                         axi_rst_n,

  input  logic [DATA_W-1:0]            s_axis_wr_tdata,
  input  logic                         s_axis_wr_tvalid,
  output logic                         s_axis_wr_tready,
  input  logic                         s_axis_wr_tlast,

  // ---- SD domain: payload out to the block layer ---------------------------
  input  logic                         sd_clk,
  input  logic                         sd_rst_n,
  input  logic                         sd_rd_en,
  output logic [DATA_W-1:0]            sd_rd_data,
  output logic                         sd_rd_last,
  output logic                         sd_rd_valid,
  output logic [$clog2(FIFO_DEPTH):0]  sd_rd_level,
  output logic                         sd_block_ready // a full block buffered
);

  // 512 bytes per block, Table 5-1.
  localparam int BLOCK_WORDS = (512 * 8) / DATA_W;

  logic              fifo_full;
  logic [DATA_W:0]   fifo_wr_data;
  logic [DATA_W:0]   fifo_rd_data;

  assign fifo_wr_data     = {s_axis_wr_tlast, s_axis_wr_tdata};
  assign s_axis_wr_tready = !fifo_full;

  assign sd_rd_data = fifo_rd_data[DATA_W-1:0];
  assign sd_rd_last = fifo_rd_data[DATA_W];

  assign sd_block_ready = (sd_rd_level >= ($clog2(FIFO_DEPTH)+1)'(BLOCK_WORDS));

  /* verilator lint_off PINCONNECTEMPTY */
  async_fifo #(
    .DATA_W  (DATA_W + 1),
    .DEPTH   (FIFO_DEPTH)
  ) u_fifo (
    .wr_clk   (axi_clk),
    .wr_rst_n (axi_rst_n),
    .wr_en    (s_axis_wr_tvalid && s_axis_wr_tready),
    .wr_data  (fifo_wr_data),
    .wr_full  (fifo_full),
    .wr_level (),
    .rd_clk   (sd_clk),
    .rd_rst_n (sd_rst_n),
    .rd_en    (sd_rd_en),
    .rd_data  (fifo_rd_data),
    .rd_valid (sd_rd_valid),
    .rd_level (sd_rd_level)
  );
  /* verilator lint_on PINCONNECTEMPTY */

endmodule

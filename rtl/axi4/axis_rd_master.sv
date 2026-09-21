// -----------------------------------------------------------------------------
// axis_rd_master
//   Purpose      : AXI4-Stream master for the read payload, card -> host. The
//                  SD side writes payload words at the SD clock, the AXI side
//                  presents them as stream beats at the system clock, and the
//                  async_fifo between the two is the documented crossing.
//
//                  Beat counting lives here, because tlast is a property of the
//                  request and not of the card: the beat count for the whole
//                  request is loaded at xfer_start and tlast is asserted on the
//                  final beat only (R-IF-6). On xfer_abort the module still
//                  produces the remaining beats -- zero-filled -- so that a host
//                  waiting on the declared beat count cannot hang and tlast
//                  still lands exactly once.
//
//                  xfer_abort shall be asserted only after the card-side
//                  producer has stopped writing; the flush drains what is left
//                  in the FIFO, it does not race a live producer.
//
//   Clock domain : two. axi_clk carries the stream and the beat counter;
//                  sd_clk carries the payload input. They are unrelated.
//   Reset scheme : axi_rst_n / sd_rst_n, async assert / sync deassert (R-CLK-1)
//   Implements   : R-IF-5, R-IF-6, R-IF-7, R-CLK-3
// -----------------------------------------------------------------------------
module axis_rd_master #(
  parameter int unsigned DATA_W     = 32,
  parameter int unsigned FIFO_DEPTH = 1024
) (
  // ---- AXI / system domain -------------------------------------------------
  input  logic                         axi_clk,
  input  logic                         axi_rst_n,

  input  logic                         xfer_start,  // pulse, loads xfer_beats
  input  logic [31:0]                  xfer_beats,  // N*512/(DATA_W/8)
  input  logic                         xfer_abort,  // pulse, zero-fill the rest
  output logic                         xfer_busy,

  output logic [DATA_W-1:0]            m_axis_rd_tdata,
  output logic                         m_axis_rd_tvalid,
  input  logic                         m_axis_rd_tready,
  output logic                         m_axis_rd_tlast,

  // ---- SD domain: payload in from the block layer ---------------------------
  input  logic                         sd_clk,
  input  logic                         sd_rst_n,
  input  logic                         sd_wr_en,
  input  logic [DATA_W-1:0]            sd_wr_data,
  output logic                         sd_wr_full,  // throttle the card
  output logic [$clog2(FIFO_DEPTH):0]  sd_wr_level
);

  logic [DATA_W-1:0] fifo_rd_data;
  logic              fifo_rd_valid;
  logic              fifo_rd_en;

  /* verilator lint_off PINCONNECTEMPTY */
  async_fifo #(
    .DATA_W  (DATA_W),
    .DEPTH   (FIFO_DEPTH)
  ) u_fifo (
    .wr_clk   (sd_clk),
    .wr_rst_n (sd_rst_n),
    .wr_en    (sd_wr_en),
    .wr_data  (sd_wr_data),
    .wr_full  (sd_wr_full),
    .wr_level (sd_wr_level),
    .rd_clk   (axi_clk),
    .rd_rst_n (axi_rst_n),
    .rd_en    (fifo_rd_en),
    .rd_data  (fifo_rd_data),
    .rd_valid (fifo_rd_valid),
    .rd_level ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  logic [31:0] beats_left_q;
  logic        flush_q;

  assign xfer_busy = (beats_left_q != 32'h0);

  // While flushing, the beat is manufactured here rather than taken from the
  // FIFO, so tvalid does not depend on a producer that has already stopped.
  assign m_axis_rd_tvalid = xfer_busy && (flush_q || fifo_rd_valid);
  assign m_axis_rd_tdata  = flush_q ? '0 : fifo_rd_data;
  assign m_axis_rd_tlast  = xfer_busy && (beats_left_q == 32'h1);

  // A FIFO word is consumed by an accepted beat, and during a flush it is
  // consumed as fast as it appears, so nothing stale survives into the next
  // request.
  assign fifo_rd_en = flush_q ? fifo_rd_valid
                              : (m_axis_rd_tvalid && m_axis_rd_tready);

  always_ff @(posedge axi_clk or negedge axi_rst_n) begin
    if (!axi_rst_n) begin
      beats_left_q <= 32'h0;
      flush_q      <= 1'b0;
    end else begin
      if (xfer_start) begin
        beats_left_q <= xfer_beats;
        flush_q      <= 1'b0;
      end else begin
        if (xfer_abort && xfer_busy) begin
          flush_q <= 1'b1;
        end
        if (m_axis_rd_tvalid && m_axis_rd_tready) begin
          beats_left_q <= beats_left_q - 1'b1;
          if (beats_left_q == 32'h1) begin
            flush_q <= 1'b0; // last beat of the request retires the flush
          end
        end
      end
    end
  end

endmodule

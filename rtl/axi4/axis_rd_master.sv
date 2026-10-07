

module axis_rd_master #(
  parameter int DATA_W     = 32,
  parameter int FIFO_DEPTH = 1024
) (

  input  logic                         axi_clk,
  input  logic                         axi_rst_n,

  input  logic                         xfer_start,
  input  logic [31:0]                  xfer_beats,
  input  logic                         xfer_abort,
  output logic                         xfer_busy,

  output logic [DATA_W-1:0]            m_axis_rd_tdata,
  output logic                         m_axis_rd_tvalid,
  input  logic                         m_axis_rd_tready,
  output logic                         m_axis_rd_tlast,

  input  logic                         sd_clk,
  input  logic                         sd_rst_n,
  input  logic                         sd_wr_en,
  input  logic [DATA_W-1:0]            sd_wr_data,

  input  logic                         sd_wr_commit,
  input  logic                         sd_wr_rewind,
  output logic                         sd_wr_full,
  output logic                         sd_wr_block_room,
  output logic [$clog2(FIFO_DEPTH):0]  sd_wr_level
);

  localparam int BLOCK_WORDS = (512 * 8) / DATA_W;

  logic room_ok_q;

  always_ff @(posedge sd_clk or negedge sd_rst_n) begin
    if (!sd_rst_n) begin
      room_ok_q <= 1'b0;
    end else begin
      room_ok_q <= (($clog2(FIFO_DEPTH)+1)'(FIFO_DEPTH) - sd_wr_level)
                   >= ($clog2(FIFO_DEPTH)+1)'(BLOCK_WORDS + 1);
    end
  end

  assign sd_wr_block_room = room_ok_q;

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
    .wr_en     (sd_wr_en),
    .wr_data   (sd_wr_data),
    .wr_commit (sd_wr_commit),
    .wr_rewind (sd_wr_rewind),
    .wr_full   (sd_wr_full),
    .wr_level  (sd_wr_level),
    .rd_clk   (axi_clk),
    .rd_rst_n (axi_rst_n),
    .rd_en     (fifo_rd_en),
    .rd_commit (1'b1),
    .rd_rewind (1'b0),
    .rd_data   (fifo_rd_data),
    .rd_valid  (fifo_rd_valid),
    .rd_level  ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  logic [31:0] beats_left_q;
  logic        flush_q;

  assign xfer_busy = (beats_left_q != 32'h0);

  assign m_axis_rd_tvalid = xfer_busy && (flush_q || fifo_rd_valid);
  assign m_axis_rd_tdata  = flush_q ? '0 : fifo_rd_data;
  assign m_axis_rd_tlast  = xfer_busy && (beats_left_q == 32'h1);

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
            flush_q <= 1'b0;
          end
        end
      end
    end
  end

endmodule

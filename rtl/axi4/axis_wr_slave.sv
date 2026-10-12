

module axis_wr_slave #(
  parameter int DATA_W     = 32,
  parameter int FIFO_DEPTH = 1024
) (

  input  logic                         axi_clk,
  input  logic                         axi_rst_n,
  input  logic                         axi_soft_clr,

  input  logic [DATA_W-1:0]            s_axis_wr_tdata,
  input  logic                         s_axis_wr_tvalid,
  output logic                         s_axis_wr_tready,
  input  logic                         s_axis_wr_tlast,

  input  logic                         sd_clk,
  input  logic                         sd_rst_n,
  input  logic                         sd_soft_clr,
  input  logic                         sd_rd_en,

  input  logic                         sd_rd_commit,
  input  logic                         sd_rd_rewind,
  output logic [DATA_W-1:0]            sd_rd_data,
  output logic                         sd_rd_last,
  output logic                         sd_rd_valid,
  output logic [$clog2(FIFO_DEPTH):0]  sd_rd_level,
  output logic                         sd_block_ready
);

  localparam int BLOCK_WORDS = (512 * 8) / DATA_W;

  logic              fifo_full;
  logic [DATA_W:0]   fifo_wr_data;
  logic [DATA_W:0]   fifo_rd_data;

  assign fifo_wr_data     = {s_axis_wr_tlast, s_axis_wr_tdata};
  assign s_axis_wr_tready = !fifo_full;

  assign sd_rd_data = fifo_rd_data[DATA_W-1:0];
  assign sd_rd_last = fifo_rd_data[DATA_W];

  logic block_ready_q;

  always_ff @(posedge sd_clk or negedge sd_rst_n) begin
    if (!sd_rst_n) begin
      block_ready_q <= 1'b0;
    end else begin
      block_ready_q <= (sd_rd_level >= ($clog2(FIFO_DEPTH)+1)'(BLOCK_WORDS));

      if (sd_soft_clr) begin
        block_ready_q <= 1'b0;

      end
    end
  end

  assign sd_block_ready = block_ready_q;

  /* verilator lint_off PINCONNECTEMPTY */
  async_fifo #(
    .DATA_W  (DATA_W + 1),
    .DEPTH   (FIFO_DEPTH)
  ) u_fifo (
    .wr_clk   (axi_clk),
    .wr_rst_n (axi_rst_n),
    .wr_soft_clr (axi_soft_clr),
    .wr_en     (s_axis_wr_tvalid && s_axis_wr_tready),
    .wr_data   (fifo_wr_data),
    .wr_commit (1'b1),
    .wr_rewind (1'b0),
    .wr_full   (fifo_full),
    .wr_level  (),
    .rd_clk   (sd_clk),
    .rd_rst_n (sd_rst_n),
    .rd_soft_clr (sd_soft_clr),
    .rd_en     (sd_rd_en),
    .rd_commit (sd_rd_commit),
    .rd_rewind (sd_rd_rewind),
    .rd_data   (fifo_rd_data),
    .rd_valid  (sd_rd_valid),
    .rd_level  (sd_rd_level)
  );
  /* verilator lint_on PINCONNECTEMPTY */

endmodule



module async_fifo #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 1024
) (

  input  logic                     wr_clk,
  input  logic                     wr_rst_n,
  input  logic                     wr_en,
  input  logic [DATA_W-1:0]        wr_data,
  input  logic                     wr_commit,
  input  logic                     wr_rewind,
  output logic                     wr_full,
  output logic [$clog2(DEPTH):0]   wr_level,

  input  logic                     rd_clk,
  input  logic                     rd_rst_n,
  input  logic                     rd_en,
  input  logic                     rd_commit,
  input  logic                     rd_rewind,
  output logic [DATA_W-1:0]        rd_data,
  output logic                     rd_valid,
  output logic [$clog2(DEPTH):0]   rd_level
);

  localparam int AW = $clog2(DEPTH);

  logic [DATA_W-1:0] mem [DEPTH];

  logic [AW:0] wptr_bin, wptr_gray;
  logic [AW:0] rptr_bin, rptr_gray;

  logic [AW:0] rptr_gray_wr_s1, rptr_gray_wr_s2;
  logic [AW:0] wptr_gray_rd_s1, wptr_gray_rd_s2;

  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    return b ^ (b >> 1);
  endfunction

  function automatic logic [AW:0] gray2bin(input logic [AW:0] g);
    logic [AW:0] b;
    b = g;
    for (int i = 1; i <= AW; i++) begin
      b = b ^ (g >> i);
    end
    return b;
  endfunction

  logic [AW:0] rptr_bin_wr_q;
  logic [AW:0] rptr_bin_wr;
  logic [AW:0] wptr_pub;
  logic [AW:0] wptr_nxt;
  logic        wr_push;

  assign rptr_bin_wr = rptr_bin_wr_q;

  assign wr_level    = wptr_bin - rptr_bin_wr;
  assign wr_full     = (wr_level == (AW+1)'(DEPTH));

  assign wr_push  = wr_en && !wr_full;
  assign wptr_nxt = wptr_bin + {{AW{1'b0}}, wr_push};

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wptr_bin        <= '0;
      wptr_pub        <= '0;
      wptr_gray       <= '0;
      rptr_gray_wr_s1 <= '0;
      rptr_gray_wr_s2 <= '0;
      rptr_bin_wr_q   <= '0;
    end else begin

      rptr_gray_wr_s1 <= rptr_gray;
      rptr_gray_wr_s2 <= rptr_gray_wr_s1;
      rptr_bin_wr_q   <= gray2bin(rptr_gray_wr_s2);

      if (wr_rewind) begin
        wptr_bin <= wptr_pub;
      end else begin
        wptr_bin <= wptr_nxt;
        if (wr_commit) begin
          wptr_pub  <= wptr_nxt;
          wptr_gray <= bin2gray(wptr_nxt);
        end
      end
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_en && !wr_full) begin
      mem[wptr_bin[AW-1:0]] <= wr_data;
    end
  end

  logic [AW:0] wptr_bin_rd_q;
  logic [AW:0] wptr_bin_rd;
  logic [AW:0] raw_count;
  logic        raw_empty;
  logic        prefetch;
  logic [AW:0] rcons_bin;
  logic [AW:0] rcons_pub;
  logic [AW:0] rcons_nxt;
  logic        rd_pop;

  assign wptr_bin_rd = wptr_bin_rd_q;
  assign raw_count   = wptr_bin_rd - rptr_bin;
  assign raw_empty   = (raw_count == '0);

  assign rd_pop    = rd_en && rd_valid;
  assign rcons_nxt = rcons_bin + {{AW{1'b0}}, rd_pop};

  assign prefetch  = !raw_empty && (!rd_valid || rd_en);
  assign rd_level  = raw_count + {{AW{1'b0}}, rd_valid};

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rptr_bin        <= '0;
      rcons_bin       <= '0;
      rcons_pub       <= '0;
      rptr_gray       <= '0;
      wptr_gray_rd_s1 <= '0;
      wptr_gray_rd_s2 <= '0;
      wptr_bin_rd_q   <= '0;
      rd_valid        <= 1'b0;
    end else begin

      wptr_gray_rd_s1 <= wptr_gray;
      wptr_gray_rd_s2 <= wptr_gray_rd_s1;
      wptr_bin_rd_q   <= gray2bin(wptr_gray_rd_s2);

      if (rd_rewind) begin

        rptr_bin  <= rcons_pub;
        rcons_bin <= rcons_pub;
        rd_valid  <= 1'b0;
      end else begin
        rcons_bin <= rcons_nxt;
        if (rd_commit) begin
          rcons_pub <= rcons_nxt;
          rptr_gray <= bin2gray(rcons_nxt);
        end

        if (prefetch) begin
          rptr_bin <= rptr_bin + 1'b1;
          rd_valid <= 1'b1;
        end else if (rd_en) begin
          rd_valid <= 1'b0;
        end
      end
    end
  end

  always_ff @(posedge rd_clk) begin
    if (prefetch) begin
      rd_data <= mem[rptr_bin[AW-1:0]];
    end
  end

endmodule

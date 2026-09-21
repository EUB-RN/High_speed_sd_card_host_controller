// -----------------------------------------------------------------------------
// async_fifo
//   Purpose      : Dual-clock FIFO, the only data-carrying crossing structure
//                  in the design (R-CLK-3). Gray-coded pointers exchanged
//                  through two-flop synchronisers; storage is a simple dual-
//                  port array so that Gowin infers BSRAM rather than LUT RAM
//                  (Table 9-2).
//
//                  The read side is show-ahead: rd_valid presents the next word
//                  before rd_en is asserted, so a consumer never pays a cycle
//                  of read latency. That is what keeps the inter-block gap of
//                  metric L4 small. It is implemented with a one-word prefetch
//                  register in front of the synchronous memory read, not with a
//                  combinational memory read, because BSRAM has no async port.
//
//                  Both sides expose a level count. The write side uses it to
//                  throttle the card (R-IF-7); the read side uses it to refuse
//                  to start a block it cannot finish (R-IF-8).
//
//                  There is no cross-domain flush: emptying the FIFO means
//                  resetting it, and both domain resets are driven together by
//                  CTRL.SOFT_RESET.
//
//   Clock domain : two. wr_clk and rd_clk are independent and unrelated; here
//                  one of them is the AXI system clock and the other the SD
//                  clock, whose ratio changes at runtime with CFG_CLK.
//   Reset scheme : wr_rst_n / rd_rst_n, each asynchronously asserted and
//                  synchronously deasserted in its own domain (R-CLK-1).
//   Implements   : R-CLK-3 (documented CDC structure), R-IF-7, R-IF-8
// -----------------------------------------------------------------------------
module async_fifo #(
  parameter int unsigned DATA_W = 32,
  parameter int unsigned DEPTH  = 1024 // must be a power of two
) (
  // ---- write side ----------------------------------------------------------
  input  logic                     wr_clk,
  input  logic                     wr_rst_n,
  input  logic                     wr_en,
  input  logic [DATA_W-1:0]        wr_data,
  output logic                     wr_full,
  output logic [$clog2(DEPTH):0]   wr_level, // words in the FIFO, write view

  // ---- read side, show-ahead -----------------------------------------------
  input  logic                     rd_clk,
  input  logic                     rd_rst_n,
  input  logic                     rd_en,    // consume the presented word
  output logic [DATA_W-1:0]        rd_data,
  output logic                     rd_valid,
  output logic [$clog2(DEPTH):0]   rd_level  // words available, read view
);

  localparam int unsigned AW = $clog2(DEPTH);

  // Storage. One write port, one read port, two clocks -> BSRAM.
  logic [DATA_W-1:0] mem [DEPTH];

  // Pointers carry one extra bit so that full and empty are distinguishable.
  logic [AW:0] wptr_bin, wptr_gray;
  logic [AW:0] rptr_bin, rptr_gray;

  // Synchronised copies of the opposite side's pointer.
  logic [AW:0] rptr_gray_wr_s1, rptr_gray_wr_s2;
  logic [AW:0] wptr_gray_rd_s1, wptr_gray_rd_s2;

  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    return b ^ (b >> 1);
  endfunction

  function automatic logic [AW:0] gray2bin(input logic [AW:0] g);
    logic [AW:0] b;
    b = g;
    for (int unsigned i = 1; i <= AW; i++) begin
      b = b ^ (g >> i);
    end
    return b;
  endfunction

  // ---------------------------------------------------------------------------
  // Write domain
  // ---------------------------------------------------------------------------
  logic [AW:0] rptr_bin_wr;

  assign rptr_bin_wr = gray2bin(rptr_gray_wr_s2);
  assign wr_level    = wptr_bin - rptr_bin_wr;
  assign wr_full     = (wr_level == (AW+1)'(DEPTH));

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wptr_bin        <= '0;
      wptr_gray       <= '0;
      rptr_gray_wr_s1 <= '0;
      rptr_gray_wr_s2 <= '0;
    end else begin
      // CDC: read pointer, gray-coded, two-flop synchroniser. Only one bit can
      // change per increment, so a sample taken mid-transition is either the
      // old or the new value and never a nonsense count.
      rptr_gray_wr_s1 <= rptr_gray;
      rptr_gray_wr_s2 <= rptr_gray_wr_s1;

      if (wr_en && !wr_full) begin
        wptr_bin  <= wptr_bin + 1'b1;
        wptr_gray <= bin2gray(wptr_bin + 1'b1);
      end
    end
  end

  always_ff @(posedge wr_clk) begin
    if (wr_en && !wr_full) begin
      mem[wptr_bin[AW-1:0]] <= wr_data;
    end
  end

  // ---------------------------------------------------------------------------
  // Read domain
  // ---------------------------------------------------------------------------
  logic [AW:0] wptr_bin_rd;
  logic [AW:0] raw_count;
  logic        raw_empty;
  logic        prefetch;

  assign wptr_bin_rd = gray2bin(wptr_gray_rd_s2);
  assign raw_count   = wptr_bin_rd - rptr_bin;
  assign raw_empty   = (raw_count == '0);

  // Take a word out of memory whenever the prefetch register is empty or is
  // being consumed this cycle.
  assign prefetch  = !raw_empty && (!rd_valid || rd_en);
  assign rd_level  = raw_count + {{AW{1'b0}}, rd_valid};

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rptr_bin        <= '0;
      rptr_gray       <= '0;
      wptr_gray_rd_s1 <= '0;
      wptr_gray_rd_s2 <= '0;
      rd_valid        <= 1'b0;
    end else begin
      // CDC: write pointer, gray-coded, two-flop synchroniser.
      wptr_gray_rd_s1 <= wptr_gray;
      wptr_gray_rd_s2 <= wptr_gray_rd_s1;

      if (prefetch) begin
        rptr_bin  <= rptr_bin + 1'b1;
        rptr_gray <= bin2gray(rptr_bin + 1'b1);
        rd_valid  <= 1'b1;
      end else if (rd_en) begin
        rd_valid  <= 1'b0;
      end
    end
  end

  // The memory read is registered on the same edge that sets rd_valid, so the
  // word and its valid flag appear together on the following cycle.
  always_ff @(posedge rd_clk) begin
    if (prefetch) begin
      rd_data <= mem[rptr_bin[AW-1:0]];
    end
  end

endmodule

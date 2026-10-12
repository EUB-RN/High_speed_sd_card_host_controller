// -----------------------------------------------------------------------------
// async_fifo
//   Dual-clock FIFO with gray-coded pointers (Clifford Cummings), plus ONE
//   addition that is not in the textbook version and is the reason this core
//   needs no block buffer: each side can hold its published pointer back and
//   either COMMIT or REWIND what it has done since.
//
//   Clock domains : wr_clk and rd_clk, unrelated (cdc.md rows 1-4)
//   Reset         : asynchronous assert, synchronous release, per domain
//   Implements    : R-IF-7 (backpressure), R-IF-8 (producer starvation),
//                   R-FUNC-9 / R-FUNC-15 (CRC16 retry without a block buffer)
//
// WHY COMMIT / REWIND EXISTS
//
// CRC16 is checked as the block streams (R-FUNC-9), which means the host-bound
// words of a block are already written into this FIFO by the time the CRC at
// the end of that block says whether they were any good. Publishing them as
// they arrive would put corrupt payload on the AXI-Stream before anybody knew
// it was corrupt, and R-FUNC-15 then asks for the block to be retried -- which
// is impossible once the consumer has seen it.
//
// So the write side advances wptr_bin freely but only moves wptr_pub, the
// pointer the reader actually sees, when the block layer asserts wr_commit at
// a block boundary. A failed CRC asserts wr_rewind instead and wptr_bin snaps
// back to wptr_pub: the bad block is simply not there. The read side carries
// the mirror image of the same structure so that a write block the card
// rejects (R-FUNC-13) can be re-sent from the FIFO rather than from the host.
//
// A previous revision of this file deleted all of that -- pub, rcons and the
// level outputs -- leaving wr_commit, wr_rewind, rd_commit, rd_rewind tied off
// as "compatibility ports" and wr_level / rd_level undriven. That version is
// what tb_async_fifo was failing 46 of its 65 checks against, and it was worse
// than a failing test: axis_rd_master derives rd_room_ok from wr_level and
// axis_wr_slave derives sd_block_ready from rd_level, so both of those were
// being computed from an undriven net, and a CRC16 retry would have published
// the corrupt block. Restored.
// -----------------------------------------------------------------------------

module async_fifo #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 1024
) (
  // ---- write side (wr_clk) --------------------------------------------------
  input  logic                     wr_clk,
  input  logic                     wr_rst_n,
  input  logic                     wr_soft_clr,
  input  logic                     wr_en,
  input  logic [DATA_W-1:0]        wr_data,
  input  logic                     wr_commit,
  input  logic                     wr_rewind,
  output logic                     wr_full,
  output logic [$clog2(DEPTH):0]   wr_level,

  // ---- read side (rd_clk) ---------------------------------------------------
  input  logic                     rd_clk,
  input  logic                     rd_rst_n,
  input  logic                     rd_soft_clr,
  input  logic                     rd_en,
  input  logic                     rd_commit,
  input  logic                     rd_rewind,
  output logic [DATA_W-1:0]        rd_data,
  output logic                     rd_valid,
  output logic [$clog2(DEPTH):0]   rd_level

`ifdef FORMAL
  // ---- observability for test/formal/fasync_fifo.sv -------------------------
  // The proof is about the published-vs-speculative pointer algebra, so it has
  // to see the pointers. It used to read them as `u_fifo.wptr_bin` and friends,
  // which is legal SystemVerilog and silently useless here: Yosys's Verilog
  // front end does not resolve a hierarchical reference into the child's
  // driver, it creates an undriven wire of that name -- "Wire
  // fasync_fifo.\u_fifo.wptr_bin is used but has no driver" -- so every
  // property comparing against one was comparing against nothing and failed
  // at the first checked step. Exporting them under `FORMAL` is the fix, and
  // it costs the delivered design nothing: `FORMAL` is defined only by
  // test/formal/async_fifo.sby.
  ,
  output logic [$clog2(DEPTH):0]   f_wptr_bin,
  output logic [$clog2(DEPTH):0]   f_wptr_pub,
  output logic [$clog2(DEPTH):0]   f_wptr_gray,
  output logic [$clog2(DEPTH):0]   f_rptr_bin,
  output logic [$clog2(DEPTH):0]   f_rptr_gray,
  output logic [$clog2(DEPTH):0]   f_rcons_bin,
  output logic [$clog2(DEPTH):0]   f_rcons_pub,
  output logic                     f_wr_push,
  // The two synchroniser chains, needed as induction invariants: a proof by
  // induction starts from an arbitrary state and has to be told that an
  // in-flight gray value is still within DEPTH of the pointer it is chasing.
  output logic [$clog2(DEPTH):0]   f_wptr_gray_s1,
  output logic [$clog2(DEPTH):0]   f_wptr_gray_s2,
  output logic [$clog2(DEPTH):0]   f_rptr_gray_s1,
  output logic [$clog2(DEPTH):0]   f_rptr_gray_s2,
  output logic [$clog2(DEPTH):0]   f_wptr_bin_rd_q,
  output logic [$clog2(DEPTH):0]   f_rptr_bin_wr_q
`endif
);

  localparam int AW = $clog2(DEPTH);

  logic [DATA_W-1:0] mem [DEPTH];

  logic [AW:0] wptr_bin, wptr_gray;
  logic [AW:0] rptr_bin, rptr_gray;

  logic [AW:0] rptr_gray_s1, rptr_gray_s2;
  logic [AW:0] wptr_gray_s1, wptr_gray_s2;

  // Written as assignment-to-function-name rather than `return`, which is the
  // same function and is not a style preference: Yosys's Verilog frontend does
  // not accept `return` inside a function, and these two are the first thing
  // test/formal/fasync_fifo.sv proves -- if the gray round-trip is wrong, the
  // two domains disagree about what a pointer value means and every other
  // property about this FIFO is vacuous. A module that cannot be read by the
  // prover cannot be proved.
  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  function automatic logic [AW:0] gray2bin(input logic [AW:0] g);
    logic [AW:0] b;
    b = g;
    for (int i = 1; i <= AW; i++) begin
      b = b ^ (g >> i);
    end
    gray2bin = b;
  endfunction

  // ---------------------------------------------------------------------------
  // Write side
  // ---------------------------------------------------------------------------
  logic [AW:0] rptr_bin_wr_q;
  logic [AW:0] wptr_pub;
  logic [AW:0] wptr_nxt;
  logic        wr_push;

  // wptr_bin is the speculative pointer, so the level counts uncommitted words
  // too: the producer must not be told there is room it would have to rewind
  // out of.
  assign wr_level = wptr_bin - rptr_bin_wr_q;
  assign wr_full  = (wr_level == (AW+1)'(DEPTH));

  assign wr_push  = wr_en && !wr_full;
  assign wptr_nxt = wptr_bin + {{AW{1'b0}}, wr_push};

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wptr_bin      <= '0;
      wptr_pub      <= '0;
      wptr_gray     <= '0;
      rptr_gray_s1  <= '0;
      rptr_gray_s2  <= '0;
      rptr_bin_wr_q <= '0;
    end else begin
      // The synchroniser chain is deliberately OUTSIDE the soft-clear below:
      // it tracks the other domain's pointer, which the other domain clears on
      // its own schedule. Clearing it from here would publish a pointer pair
      // that neither side ever held.
      rptr_gray_s1  <= rptr_gray;
      rptr_gray_s2  <= rptr_gray_s1;
      rptr_bin_wr_q <= gray2bin(rptr_gray_s2);

      if (wr_soft_clr) begin
        wptr_bin  <= '0;
        wptr_pub  <= '0;
        wptr_gray <= '0;
      end else if (wr_rewind) begin
        // Everything written since the last commit never happened.
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
    if (wr_push) begin
      mem[wptr_bin[AW-1:0]] <= wr_data;
    end
  end

  // ---------------------------------------------------------------------------
  // Read side
  // ---------------------------------------------------------------------------
  logic [AW:0] wptr_bin_rd_q;
  logic [AW:0] raw_count;
  logic        raw_empty;
  logic        prefetch;
  logic [AW:0] rcons_bin;
  logic [AW:0] rcons_pub;
  logic [AW:0] rcons_nxt;
  logic        rd_pop;

  assign raw_count = wptr_bin_rd_q - rptr_bin;
  assign raw_empty = (raw_count == '0);

  assign rd_pop    = rd_en && rd_valid;
  assign rcons_nxt = rcons_bin + {{AW{1'b0}}, rd_pop};

  assign prefetch  = !raw_empty && (!rd_valid || rd_en);
  // The prefetched word has left the memory but not the FIFO, so it counts.
  assign rd_level  = raw_count + {{AW{1'b0}}, rd_valid};

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rptr_bin      <= '0;
      rcons_bin     <= '0;
      rcons_pub     <= '0;
      rptr_gray     <= '0;
      wptr_gray_s1  <= '0;
      wptr_gray_s2  <= '0;
      wptr_bin_rd_q <= '0;
      rd_valid      <= 1'b0;
    end else begin
      wptr_gray_s1  <= wptr_gray;
      wptr_gray_s2  <= wptr_gray_s1;
      wptr_bin_rd_q <= gray2bin(wptr_gray_s2);

      if (rd_soft_clr) begin
        rptr_bin  <= '0;
        rcons_bin <= '0;
        rcons_pub <= '0;
        rptr_gray <= '0;
        rd_valid  <= 1'b0;
      end else if (rd_rewind) begin
        // Re-read from the last committed point: this is how a write block the
        // card rejected with a negative CRC status token (R-FUNC-13) is sent
        // again without asking the host for it a second time.
        rptr_bin  <= rcons_pub;
        rcons_bin <= rcons_pub;
        rd_valid  <= 1'b0;
      end else begin
        rcons_bin <= rcons_nxt;
        if (rd_commit) begin
          rcons_pub <= rcons_nxt;
          // Only committed reads free storage for the writer.
          rptr_gray <= bin2gray(rcons_nxt);
        end

        if (prefetch) begin
          rptr_bin <= rptr_bin + (AW+1)'(1);
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

`ifdef FORMAL
  assign f_wptr_bin  = wptr_bin;
  assign f_wptr_pub  = wptr_pub;
  assign f_wptr_gray = wptr_gray;
  assign f_rptr_bin  = rptr_bin;
  assign f_rptr_gray = rptr_gray;
  assign f_rcons_bin = rcons_bin;
  assign f_rcons_pub = rcons_pub;
  assign f_wr_push   = wr_push;
  assign f_wptr_gray_s1  = wptr_gray_s1;
  assign f_wptr_gray_s2  = wptr_gray_s2;
  assign f_rptr_gray_s1  = rptr_gray_s1;
  assign f_rptr_gray_s2  = rptr_gray_s2;
  assign f_wptr_bin_rd_q = wptr_bin_rd_q;
  assign f_rptr_bin_wr_q = rptr_bin_wr_q;
`endif

endmodule

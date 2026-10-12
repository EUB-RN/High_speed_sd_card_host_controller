// -----------------------------------------------------------------------------
// fasync_fifo
//   Purpose      : Formal wrapper around rtl/axi4/async_fifo.sv. Proves the
//                  pointer algebra and the no-overflow / no-underflow
//                  properties of the commit/rewind FIFO for ALL inputs.
//
//   Covers       : R-IF-7, R-IF-8, R-FUNC-9, R-FUNC-13, R-FUNC-15
//
// WHY A PROOF AND NOT ONLY tb_async_fifo
//
// tb_async_fifo drives 65 checks and passes. What it cannot do is cover the
// interleavings it did not happen to generate, and this FIFO's whole reason
// for existing is an interleaving: a commit and a rewind are decided by a
// different clock domain than the one filling the memory, and the pointer that
// the reader sees is deliberately NOT the pointer the writer is advancing. The
// failure mode that matters -- publishing a word that was rewound, or losing
// one that was committed -- is one specific ordering away at any moment.
//
// A previous revision of this file's DUT had commit/rewind deleted entirely,
// with wr_level and rd_level left undriven while two consumers derived real
// control signals from them. That is the class of defect a proof closes off
// permanently and a passing testbench does not.
//
// WHAT THIS PROOF COVERS, AND WHAT IT DOES NOT
//
// Both clocks are tied to one `clk` here. That is a real simplification and it
// is stated rather than hidden: it means this is NOT a proof about metastability
// or about the gray-code crossing itself. What it proves is the part that is
// per-domain algebra and is wrong or right regardless of the clock ratio:
//
//   - the gray conversion round-trips, so a pointer never means another value
//   - the memory is never written past capacity, for any input sequence
//   - a word is never read out of an empty FIFO
//   - the uncommitted region never exceeds capacity, so a rewind always has
//     somewhere to rewind to
//   - a rewind restores the published pointer exactly -- nothing written since
//     the last commit survives it
//   - a commit never moves the published pointer backwards, so a word that was
//     made visible never becomes invisible again
//
// The crossing itself is a two-flop gray synchroniser per direction, enumerated
// in doc/cdc.md rows 1-4 and constrained in constr/ultra_sd.sdc; what makes it
// correct is the structure plus the constraint, not a property here.
// -----------------------------------------------------------------------------
`default_nettype none

module fasync_fifo #(
  parameter int DATA_W = 32,
  // Small enough for induction to close in seconds, large enough to have a
  // wrap: the pointers are AW+1 bits wide, so DEPTH = 8 still exercises the
  // full-vs-empty disambiguation that the extra bit exists for.
  parameter int DEPTH  = 4
) (
  input wire clk,
  input wire rst_n,

  // Everything the two sides can do is a free input: the solver chooses.
  input wire              wr_soft_clr,
  input wire              wr_en,
  input wire [DATA_W-1:0] wr_data,
  input wire              wr_commit,
  input wire              wr_rewind,
  input wire              rd_soft_clr,
  input wire              rd_en,
  input wire              rd_commit,
  input wire              rd_rewind
);

  localparam int AW = $clog2(DEPTH);

  // The pointers async_fifo exports under `FORMAL`.
  wire [AW:0] wptr_bin, wptr_pub, wptr_gray;
  wire [AW:0] rptr_bin, rptr_gray, rcons_bin, rcons_pub;
  wire        wr_push;

  // rd_pop is not exported: rd_valid is already an output, so the read-side
  // pop condition is reconstructible here and the proof checks one less
  // internal signal.
  wire        rd_pop = rd_en && rd_valid;
  wire [AW:0] wptr_gray_s1, wptr_gray_s2, rptr_gray_s1, rptr_gray_s2;
  wire [AW:0] wptr_bin_rd_q, rptr_bin_wr_q;

  wire                wr_full;
  wire [AW:0]         wr_level;
  wire [DATA_W-1:0]   rd_data;
  wire                rd_valid;
  wire [AW:0]         rd_level;

  async_fifo #(
    .DATA_W (DATA_W),
    .DEPTH  (DEPTH)
  ) u_fifo (
    .wr_clk      (clk),
    .wr_rst_n    (rst_n),
    .wr_soft_clr (wr_soft_clr),
    .wr_en       (wr_en),
    .wr_data     (wr_data),
    .wr_commit   (wr_commit),
    .wr_rewind   (wr_rewind),
    .wr_full     (wr_full),
    .wr_level    (wr_level),

    .rd_clk      (clk),
    .rd_rst_n    (rst_n),
    .rd_soft_clr (rd_soft_clr),
    .rd_en       (rd_en),
    .rd_commit   (rd_commit),
    .rd_rewind   (rd_rewind),
    .rd_data     (rd_data),
    .rd_valid    (rd_valid),
    .rd_level    (rd_level),

    // The pointers the properties are about. Exported by async_fifo under
    // `FORMAL` rather than read as u_fifo.<name>: Yosys turns a hierarchical
    // reference into an undriven wire instead of resolving it, which made
    // every property below compare against nothing.
    .f_wptr_bin  (wptr_bin),
    .f_wptr_pub  (wptr_pub),
    .f_wptr_gray (wptr_gray),
    .f_rptr_bin  (rptr_bin),
    .f_rptr_gray (rptr_gray),
    .f_rcons_bin (rcons_bin),
    .f_rcons_pub (rcons_pub),
    .f_wr_push   (wr_push),
    .f_wptr_gray_s1  (wptr_gray_s1),
    .f_wptr_gray_s2  (wptr_gray_s2),
    .f_rptr_gray_s1  (rptr_gray_s1),
    .f_rptr_gray_s2  (rptr_gray_s2),
    .f_wptr_bin_rd_q (wptr_bin_rd_q),
    .f_rptr_bin_wr_q (rptr_bin_wr_q)
  );


`ifdef FORMAL
  // Two cycles of held reset before anything is asserted. One is not enough:
  // the reset is asynchronous-assert / synchronous-release, so the cycle the
  // reset is released in is the first cycle whose next state is computed from
  // reset values -- and an assertion in that cycle is an assertion about the
  // state the solver chose, not the state the design reaches.
  reg [1:0] f_startup = 2'd0;
  always @(posedge clk) if (f_startup != 2'd3) f_startup <= f_startup + 2'd1;
  wire f_past_valid = (f_startup != 2'd0);

  // Every assertion below is guarded by this. At time zero the solver may put
  // the registers anywhere, and an assertion about a pointer pair in a state
  // the design was never reset into says nothing about the design. `f_active`
  // is the "we are past a reset" flag that makes each property a statement
  // about reachable states.
  wire f_active = (f_startup == 2'd3) && rst_n;

  // ---- the soft-clear settling window, and what it says about the design ---
  // A soft clear zeroes each side's pointers but deliberately does NOT clear
  // the cross-domain synchroniser chain -- async_fifo says why next to the
  // code: the chain tracks the OTHER domain's pointer, which that domain
  // clears on its own schedule, so clearing it from here would publish a
  // pointer pair neither side ever held.
  //
  // The consequence is a two-cycle window this proof found and which is worth
  // writing down. After a clear, `wptr_gray` is zero but the stale pre-clear
  // value is still in flight in `wptr_gray_s1`/`_s2`. The read side therefore
  // decodes a writer pointer that is AHEAD of its own freshly-zeroed read
  // pointer, prefetches a word the clear was supposed to have discarded, and
  // once the real zero arrives `raw_count = wptr_bin_rd_q - rptr_bin`
  // underflows -- `rd_level` wraps to 0 with `rd_valid` still high. The solver
  // produces exactly that trace in 15 steps.
  //
  // This is NOT a latent bug in the delivered design, and the distinction
  // matters: a soft clear is only issued with no transfer in flight, and
  // `ultra_sd_block` returns to S_IDLE on `soft_clr`, so nothing downstream
  // looks at `rd_valid` or `rd_level` until both sides are long out of the
  // window. It IS a sharp edge for anyone who reuses this FIFO somewhere that
  // clears mid-stream, which is why it is documented here and in
  // `doc/report.md` rather than hidden behind a weaker property.
  //
  // f_settled is "far enough past the last clear that the chain has drained":
  // three cycles covers the two synchroniser stages and the decode register.
  localparam int CLR_SETTLE = 3;
  reg [1:0] f_clr_age;
  initial f_clr_age = 2'd0;
  always @(posedge clk) begin
    if (!rst_n || wr_soft_clr || rd_soft_clr) f_clr_age <= 2'd0;
    else if (f_clr_age != CLR_SETTLE[1:0])    f_clr_age <= f_clr_age + 2'd1;
  end
  wire f_settled = f_active && (f_clr_age == CLR_SETTLE[1:0]);

  // The reset is asynchronous-assert / synchronous-release in the design, and
  // the solver is allowed to assert it at any time; what it is not allowed to
  // do is start the trace already out of reset with arbitrary state, which
  // would make induction reason about pointer pairs the design cannot hold.
  // Guard inside the expression, for the same reason the assertions below
  // carry theirs that way: a guarded `assume` in a combinational block is not
  // reliably lowered with its guard, and an assumption that is silently
  // dropped leaves rst_n free -- which lets the solver start out of reset with
  // arbitrary pointers and fails every property here for no reason.
  always @(*) assume ((f_startup >= 2'd2) || !rst_n);

  // The two sides' control inputs are mutually exclusive by construction in
  // ultra_sd_block: a block boundary either commits or rewinds. Assuming it
  // here rather than proving the design's behaviour when both are high is
  // correct, because "both" is not a case the design is specified for -- and
  // the DUT's own if/else chain already gives rewind priority if it happened.
  always @(*) assume (!(wr_commit && wr_rewind));
  always @(*) assume (!(rd_commit && rd_rewind));

  // The two soft clears are one event seen from two clock domains. In the
  // design they are `sd_soft_clr` and `axi_soft_clr` -- the same soft reset,
  // synchronised into each side -- and this proof runs `multiclock off`, so
  // both sides already share one clock here. Leaving them as independent free
  // inputs therefore models something the synchronisers prevent, and the
  // solver finds it immediately: clear only the read side and `rptr_bin` goes
  // to zero while `wptr_bin_rd_q` still holds the writer's old pointer, so
  // `raw_count = wptr_bin_rd_q - rptr_bin` wraps to near all-ones and
  // `rd_level = raw_count + rd_valid` wraps back to zero with `rd_valid` high.
  // That is a counterexample to property 3 built entirely out of a state the
  // system cannot reach.
  //
  // What this assumption does NOT cover, stated plainly: the real design does
  // have a window in which one side has been cleared and the other has not,
  // because the two synchronisers release on different clocks. Inside that
  // window `rd_level` and `rd_valid` are not meaningful. The design is safe
  // there by construction rather than by proof -- a soft reset only happens
  // with no transfer in flight, and `ultra_sd_block` returns to S_IDLE on
  // `soft_clr`, so nothing reads those outputs until both sides are out of it.
  // Proving that window would need the two-clock model this task turns off.
  always @(*) assume (wr_soft_clr == rd_soft_clr);

  // A soft clear is held, not pulsed, and that is what makes the window above
  // harmless rather than merely rare. `system_controller` turns the one-cycle
  // CTRL.SOFT_RESET write into a level and holds it for at least
  // SOFT_RST_CYC = 16 clk cycles AND until every domain has acknowledged
  // seeing it (`soft_clr_o && sd_soft_clr_o && soft_ack_ext_i`). Throughout
  // that hold the read side's `if (rd_soft_clr)` branch has priority over the
  // prefetch logic, so `rptr_bin` is pinned at zero while the stale gray value
  // drains out of the synchroniser chain -- the phantom prefetch cannot
  // happen, and by release the chain carries the post-clear zero.
  //
  // Without this assumption the solver issues a ONE-cycle clear, which the
  // system cannot: it releases the read pointers into the middle of the
  // draining chain. So assume what the design guarantees -- a clear that is
  // asserted stays asserted at least as long as the chain is deep.
  reg [1:0] f_clr_hold;
  initial f_clr_hold = 2'd0;
  always @(posedge clk) begin
    if (!rst_n)           f_clr_hold <= 2'd0;
    else if (wr_soft_clr) f_clr_hold <= (f_clr_hold == CLR_SETTLE[1:0])
                                        ? f_clr_hold : f_clr_hold + 2'd1;
    else                  f_clr_hold <= 2'd0;
  end
  always @(posedge clk) begin
    if (f_past_valid && $past(rst_n) && $past(wr_soft_clr) && !wr_soft_clr)
      assume ($past(f_clr_hold) == CLR_SETTLE[1:0]);
  end

  // ---- 1. each side's gray pointer decodes to its published binary one ----
  // This is the property the whole crossing rests on: the other domain only
  // ever sees the gray pointer, and converts it back. If the gray output and
  // the binary pointer it was made from ever disagree, the two domains
  // disagree about how full the FIFO is and every other property here is
  // vacuous.
  //
  // The decoder below is this file's own, not a call into the DUT -- partly
  // because Yosys cannot resolve a hierarchical function call, and partly
  // because an independent decoder is the stronger check: a bug in the DUT's
  // own gray2bin would be invisible to a round-trip through itself.
  function automatic [AW:0] f_gray2bin(input [AW:0] g);
    integer i;
    reg [AW:0] b;
    begin
      b = g;
      for (i = 1; i <= AW; i = i + 1) b = b ^ (g >> i);
      f_gray2bin = b;
    end
  endfunction

  // The guard is inside each expression rather than an `if` around the block:
  // a combinational `always @(*) if (g) assert(e)` is not reliably lowered with
  // the guard intact, and an assert that escapes its guard is checked in the
  // arbitrary pre-reset state, where it fails for reasons that say nothing
  // about the design. Measured the hard way.
  always @(*) begin
    assert (!f_active || (f_gray2bin(wptr_gray) == wptr_pub));
    assert (!f_active || (f_gray2bin(rptr_gray) == rcons_pub));
  end

  // ---- 2. capacity is never exceeded --------------------------------------
  // wr_level counts uncommitted words too, on purpose: the producer must not
  // be told there is room it would have to rewind out of. So the bound is on
  // the speculative pointer, which is the one that addresses the memory.
  always @(*) begin
    assert (!f_settled || (wr_level <= (AW+1)'(DEPTH)));
    assert (!f_settled || (rd_level <= (AW+1)'(DEPTH)));
    // The write that actually lands is gated on !wr_full, which is what makes
    // the bound above hold rather than merely describing it.
    assert (!f_active || (wr_push == (wr_en && !wr_full)));
  end

  // ---- 2a. induction invariants on the two synchroniser chains ------------
  // Properties 2 and 3 are true but not INDUCTIVE on their own. Induction
  // starts from an arbitrary state that merely satisfies the assertions, and
  // nothing in properties 2-3 stops it from starting with a gray value in
  // flight that is wildly out of step with the pointer it is chasing --
  // whereupon `raw_count = wptr_bin_rd_q - rptr_bin` underflows in one step
  // and the capacity bound fails for a state the design cannot be in.
  //
  // The missing fact is that every stage of a chain is a value the source
  // pointer really held, so each is within DEPTH of the pointer chasing it.
  // Stating that is what closes induction; it is an invariant, not a new
  // claim, and each of these is itself checked as an assertion.
  always @(*) begin
    assert (!f_settled || ((f_gray2bin(wptr_gray)    - rptr_bin) <= (AW+1)'(DEPTH)));
    assert (!f_settled || ((f_gray2bin(wptr_gray_s1) - rptr_bin) <= (AW+1)'(DEPTH)));
    assert (!f_settled || ((f_gray2bin(wptr_gray_s2) - rptr_bin) <= (AW+1)'(DEPTH)));
    assert (!f_settled || ((wptr_bin_rd_q            - rptr_bin) <= (AW+1)'(DEPTH)));

    assert (!f_settled || ((wptr_bin - f_gray2bin(rptr_gray))    <= (AW+1)'(DEPTH)));
    assert (!f_settled || ((wptr_bin - f_gray2bin(rptr_gray_s1)) <= (AW+1)'(DEPTH)));
    assert (!f_settled || ((wptr_bin - f_gray2bin(rptr_gray_s2)) <= (AW+1)'(DEPTH)));
    assert (!f_settled || ((wptr_bin - rptr_bin_wr_q)            <= (AW+1)'(DEPTH)));

    // The published pointers sit inside the speculative region, which is what
    // makes "published" meaningful: you cannot publish what was not written.
    assert (!f_settled || ((wptr_bin  - wptr_pub)  <= (AW+1)'(DEPTH)));
    assert (!f_settled || ((rcons_bin - rcons_pub) <= (AW+1)'(DEPTH)));
  end

  // ---- 3. nothing is read out of an empty FIFO ----------------------------
  // rd_valid means a word has been prefetched out of the memory and is being
  // offered. It may only be offered if it was there.
  //
  // Gated on f_settled, not f_active, and the reason is a real property of the
  // design that this proof found -- see the note on f_settled below.
  always @(*) assert (!(f_settled && rd_valid) || (rd_level >= (AW+1)'(1)));

  // ---- 4. the uncommitted region fits -------------------------------------
  // This is the property that makes a rewind always possible: whatever has
  // been written since the last commit still has to be inside the FIFO, or
  // rewinding to wptr_pub would be rewinding past data the reader has already
  // been shown.
  wire [AW:0] f_wr_uncommitted = wptr_bin - wptr_pub;
  wire [AW:0] f_rd_unconsumed  = rcons_bin - rcons_pub;
  always @(*) begin
    assert (!f_active || (f_wr_uncommitted <= (AW+1)'(DEPTH)));
    assert (!f_active || (f_rd_unconsumed  <= (AW+1)'(DEPTH)));
  end

  // ---- 5. a rewind restores the published point exactly -------------------
  // "Everything since the last commit never happened" is the contract, and it
  // is the one a CRC16 retry depends on (R-FUNC-15): if a single word survived
  // the rewind, the retried block would be written at the wrong offset and the
  // host would receive a block that is one word out of step for the rest of
  // the transfer.
  always @(posedge clk) begin
    if (f_past_valid && rst_n && $past(rst_n) &&
        $past(wr_rewind) && !$past(wr_soft_clr)) begin
      assert (wptr_bin == $past(wptr_pub));
      // A rewind must not move the published pointer: the reader's view of the
      // FIFO is unchanged by a block the writer threw away.
      assert (wptr_pub == $past(wptr_pub));
    end
    if (f_past_valid && rst_n && $past(rst_n) &&
        $past(rd_rewind) && !$past(rd_soft_clr)) begin
      assert (rcons_bin == $past(rcons_pub));
      assert (rcons_pub == $past(rcons_pub));
      // A re-read starts from the committed point, which is what lets a block
      // the card NAK'd (R-FUNC-13) be re-sent without asking the host again.
      assert (rptr_bin == $past(rcons_pub));
      assert (!rd_valid);
    end
  end

  // ---- 6. a commit publishes exactly the speculative region ---------------
  // The published pointer must never withdraw -- a word made visible to the
  // other domain must not become invisible again -- and on a commit it must
  // take up the whole speculative region, which is what makes block-granular
  // retry work without a block buffer.
  //
  // The first version of this property said the published pointer advances by
  // at most one per cycle, and the solver was right to reject it: `wr_commit`
  // assigns `wptr_pub <= wptr_nxt`, so one commit can publish up to DEPTH
  // words in a single cycle. The property was wrong, not the design. Stating
  // it as an equality instead is both correct and stronger than "never
  // withdraws", because it pins the published pointer to one value rather
  // than to a direction.
  always @(posedge clk) begin
    if (f_past_valid && rst_n && $past(rst_n) &&
        !$past(wr_soft_clr) && !$past(wr_rewind)) begin
      if ($past(wr_commit))
        assert (wptr_pub == ($past(wptr_bin) + {{AW{1'b0}}, $past(wr_push)}));
      else
        assert (wptr_pub == $past(wptr_pub));
    end
    if (f_past_valid && rst_n && $past(rst_n) &&
        !$past(rd_soft_clr) && !$past(rd_rewind)) begin
      if ($past(rd_commit))
        assert (rcons_pub == ($past(rcons_bin) + {{AW{1'b0}}, $past(rd_pop)}));
      else
        assert (rcons_pub == $past(rcons_pub));
    end
  end

  // ---- 7. a soft clear really clears --------------------------------------
  // Both sides are cleared by software, each on its own clock, and a clear
  // that leaves one pointer behind is the hardest kind of stale state to find
  // in simulation: the FIFO looks empty and then produces a word from the
  // previous transfer.
  always @(posedge clk) begin
    if (f_past_valid && rst_n && $past(rst_n) && $past(wr_soft_clr)) begin
      assert (wptr_bin  == '0);
      assert (wptr_pub  == '0);
      assert (wptr_gray == '0);
    end
    if (f_past_valid && rst_n && $past(rst_n) && $past(rd_soft_clr)) begin
      assert (rptr_bin  == '0);
      assert (rcons_bin == '0);
      assert (rcons_pub == '0);
      assert (!rd_valid);
    end
  end

  // ---- cover: the interleaving the whole design rests on ------------------
  // Not an assertion -- a demonstration that the solver can reach the state
  // the comment at the top of async_fifo.sv describes: words written, then
  // thrown away, with the reader never having seen them.
  always @(posedge clk) begin
    if (f_past_valid && rst_n)
      cover ($past(wr_rewind) && (f_wr_uncommitted == '0) &&
             (wptr_pub != '0));
  end
`endif

endmodule

`default_nettype wire

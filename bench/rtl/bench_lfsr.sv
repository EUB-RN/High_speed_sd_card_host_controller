// -----------------------------------------------------------------------------
// bench_lfsr
//   Purpose      : The payload generator, used twice over: once as the source
//                  for the write stream and once as the expected value for the
//                  read stream. Both instances are reset to the same seed at the
//                  start of a run, so a read mismatch means the card gave back
//                  something other than what went in -- no memory of the written
//                  data is kept anywhere, which is the point. 64 MB of expected
//                  payload costs 32 flops.
//
//                  32-bit maximal-length Fibonacci LFSR, x^32 + x^22 + x^2 + x
//                  + 1, one step per beat. Period 2^32-1 beats = 16 GB, so a
//                  64 MB run never repeats a word.
//
//                  THIS IS OUR BENCH, NOT THE ACCEPTANCE HARNESS. Section 12.1
//                  specifies a 64-bit LFSR in the client's harness and R-MEAS-1
//                  forbids modifying it; that harness is what decides the tier.
//                  This generator exists so we can measure and catch corruption
//                  before we ever see theirs, and one step per beat keeps it to
//                  a single XOR on the critical path at 99 MHz.
//
//   Clock domain : clk only.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module bench_lfsr (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        reload_i,   // restart the sequence from the seed
  input  logic        step_i,     // one beat consumed
  output logic [31:0] data_o
);

  // Any non-zero value works; this one is just recognisable in a waveform.
  localparam logic [31:0] SEED = 32'hace1_2345;

  logic [31:0] state_q;
  logic        fb;

  assign fb     = state_q[31] ^ state_q[21] ^ state_q[1] ^ state_q[0];
  assign data_o = state_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)        state_q <= SEED;
    else if (reload_i) state_q <= SEED;
    else if (step_i)   state_q <= {state_q[30:0], fb};
  end

endmodule

// -----------------------------------------------------------------------------
// ultra_sd_block
//   Purpose      : L3. LBA -> block sequencing, multi-block streaming (CMD18/CMD25),
//                  block FIFOs and backpressure handling. No vendor
//                  primitives, no raw bit shifting, no AXI signalling.
//   Clock domain : clk (system clock); block FIFOs cross to the SD clock domain
//   Reset scheme : rst_n, async assert / sync deassert
//   Implements   : Spec Sections 6 (functional), R-IF-6 .. R-IF-8, Section 11
//                  latency metric L4
// -----------------------------------------------------------------------------
module ultra_sd_block
  import ultra_sd_pkg::*;
#(
  parameter int unsigned DATA_W         = 32,
  parameter int unsigned RD_FIFO_BLOCKS = 2,
  parameter int unsigned WR_FIFO_BLOCKS = 2
) (
  input logic clk,
  input logic rst_n
  // TODO: request interface from L4, payload FIFOs, command requests to L2.
);
endmodule

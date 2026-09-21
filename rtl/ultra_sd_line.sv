// -----------------------------------------------------------------------------
// ultra_sd_line
//   Purpose      : L1. CMD serialise/deserialise, DAT nibble pack/unpack, start and
//                  end framing bits. Bit-level only -- no command sequencing
//                  and no vendor primitives.
//   Clock domain : sd_clk domain
//   Reset scheme : rst_n, async assert / sync deassert
//   Implements   : Spec Section 4.2 (layer responsibilities), Appendix A framing
// -----------------------------------------------------------------------------
module ultra_sd_line
  import ultra_sd_pkg::*;
(
  input logic clk,
  input logic rst_n
  // TODO: CMD shift register with CRC7, DAT 1-bit/4-bit framing to the PHY.
);
endmodule

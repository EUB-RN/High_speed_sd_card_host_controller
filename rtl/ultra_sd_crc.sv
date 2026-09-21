// -----------------------------------------------------------------------------
// ultra_sd_crc
//   Purpose      : L1. One CRC lane: CRC7 for commands and responses, and a single
//                  CRC16 lane for data. Instantiated four times by a generate
//                  loop for the four data lines (R-ARCH-5); CRC16 is per data
//                  line and NOT over the reassembled byte stream (hazard D-1).
//   Clock domain : sd_clk domain
//   Reset scheme : rst_n, async assert / sync deassert
//   Implements   : Spec Appendix A Table A-3, R-FUNC-9, R-FUNC-13
// -----------------------------------------------------------------------------
module ultra_sd_crc
  import ultra_sd_pkg::*;
#(
  parameter int unsigned WIDTH = 16 // 7 for CRC7, 16 for one CRC16 lane
) (
  input logic clk,
  input logic rst_n
  // TODO: serial-in, clear, bit-at-a-time update, running remainder out.
);
endmodule

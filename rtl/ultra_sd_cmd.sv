// -----------------------------------------------------------------------------
// ultra_sd_cmd
//   Purpose      : L2. Command issue and response parsing: CMD/ACMD sequencing,
//                  response decode, card state tracking, retry and recovery
//                  policy. No vendor primitives, no AXI signalling, no user
//                  FIFOs.
//   Clock domain : sd_clk domain (SD clock derived in the PHY)
//   Reset scheme : rst_n, async assert / sync deassert
//   Implements   : Spec Section 6, Appendix A (commands and response formats),
//                  R-FUNC-16, R-FUNC-17 (bounded named timeouts)
// -----------------------------------------------------------------------------
module ultra_sd_cmd
  import ultra_sd_pkg::*;
(
  input logic clk,
  input logic rst_n
  // TODO: command request/ack to L3 and L1, response decode, error classing.
);
endmodule

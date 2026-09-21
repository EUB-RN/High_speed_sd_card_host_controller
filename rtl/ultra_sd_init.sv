// -----------------------------------------------------------------------------
// ultra_sd_init
//   Purpose      : L2. Initialisation FSM: the ladder of Section 6.1 and Appendix B,
//                  executed entirely in hardware with no software assistance.
//   Clock domain : sd_clk domain
//   Reset scheme : rst_n, async assert / sync deassert
//   Implements   : Spec Section 6.1 (init ladder), Appendix B (flowchart),
//                  R-FUNC-1, R-FUNC-2 (74-clock ramp), R-FUNC-3, R-FUNC-5
// -----------------------------------------------------------------------------
module ultra_sd_init
  import ultra_sd_pkg::*;
(
  input logic clk,
  input logic rst_n
  // TODO: 74-clock ramp, CMD0/8, ACMD41 with HCS, CMD2/3/9/7, ACMD51/ACMD6,
  //       CMD6 High Speed switch with status-block read-back.
);
endmodule

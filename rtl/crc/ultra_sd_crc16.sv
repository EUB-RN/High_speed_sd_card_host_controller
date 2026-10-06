// -----------------------------------------------------------------------------
// ultra_sd_crc16
//   Purpose      : L1. Purely combinational CRC16-CCITT for ONE SD data line,
//                  as a flat XOR matrix. IN_WIDTH bits of this lane are folded
//                  in ONE gate level of AND-mask plus one balanced XOR tree per
//                  output bit -- not a chain of IN_WIDTH shift-and-reduce
//                  stages. All 16 output bits are computed in parallel and
//                  independently, so logic depth is ceil(log2(terms)) and does
//                  not grow with IN_WIDTH the way a serial unroll would.
//
//                  In 4-bit mode each of DAT0..DAT3 carries its own independent
//                  bit stream and therefore its own CRC16 -- this is NOT one CRC
//                  over the reassembled byte stream (hazard D-1). Instantiate
//                  four times from a generate loop, one per lane (R-ARCH-5);
//                  never copy-paste the four lanes. Widening IN_WIDTH must mean
//                  "more bits of THIS lane", never "bits from other lanes" --
//                  that is exactly the D-1 bug.
//   Clock domain : none -- combinational. The remainder register lives in the
//                  caller (ultra_sd_line), which owns clear at block start and
//                  enable while the data window is valid, so the check happens
//                  on the fly and not after buffering the block (R-FUNC-9).
//   Reset scheme : none (no state)
//   Implements   : Spec Appendix A Table A-3 (x^16 + x^12 + x^5 + 1, CCITT,
//                  per data line), R-FUNC-9, R-FUNC-13
// -----------------------------------------------------------------------------
module ultra_sd_crc16
  import ultra_sd_pkg::*;
#(
  // Bits of THIS LANE's stream folded per evaluation. 1 = one bit per SD clock,
  // which is the 4-bit-mode data rate for a single lane.
  parameter int IN_WIDTH = 1,
  parameter logic [CRC16_W-1:0] POLY = CRC16_POLY
) (
  // Running remainder in. Drive CRC16_INIT at the start of a block.
  input  logic [CRC16_W-1:0]  crc_i,
  // This lane's bits, in transmission order: data_i[IN_WIDTH-1] first.
  input  logic [IN_WIDTH-1:0] data_i,
  // Remainder after all IN_WIDTH bits have been folded in.
  output logic [CRC16_W-1:0]  crc_o
);
  localparam int W     = CRC16_W;
  localparam int TERMS = W + IN_WIDTH; // the {crc_i, data_i} term vector

  // ---------------------------------------------------------------------------
  // MASK, flattened as W rows of TERMS bits: row j selects which of the TERMS
  // input bits XOR into crc_o[j].
  //
  // Evaluated at elaboration time only -- none of this becomes logic. CRC is
  // linear over GF(2), so pushing a unit basis vector through the reference
  // shift-and-reduce recurrence yields exactly that one input bit's column, and
  // the whole matrix falls out of TERMS such evaluations. The recurrence is
  // written inline rather than as a nested function call, which keeps the
  // constant-folding within what every tool in the flow supports.
  // ---------------------------------------------------------------------------
  function automatic logic [W*TERMS-1:0] build_mask();
    logic [W*TERMS-1:0] m;
    logic [W-1:0]       acc;
    logic [IN_WIDTH-1:0] d;
    logic               feedback;
    m = {(W*TERMS){1'b0}};
    for (int k = 0; k < TERMS; k++) begin
      if (k < IN_WIDTH) begin
        acc = {W{1'b0}};              // basis vector on data_i[k]
        d   = {{IN_WIDTH-1{1'b0}}, 1'b1} << k;
      end else begin
        acc = {{W-1{1'b0}}, 1'b1} << (k - IN_WIDTH); // basis on crc_i[k-IN_WIDTH]
        d   = {IN_WIDTH{1'b0}};
      end
      for (int i = IN_WIDTH; i > 0; i--) begin
        feedback = acc[W-1] ^ d[i-1];
        acc      = {acc[W-2:0], 1'b0} ^ (feedback ? POLY : {W{1'b0}});
      end
      for (int j = 0; j < W; j++) begin
        m[j*TERMS + k] = acc[j];
      end
    end
    build_mask = m;
  endfunction

  localparam logic [W*TERMS-1:0] MASK = build_mask();

  // Term vector: terms[IN_WIDTH-1:0] = data_i, terms[TERMS-1:IN_WIDTH] = crc_i.
  // The mask row ordering above matches this layout.
  logic [TERMS-1:0] terms;
  assign terms = {crc_i, data_i};

  // W independent parallel XOR reductions: one AND-mask level plus one balanced
  // XOR tree per output bit. No output bit depends on another, and depth is
  // ceil(log2(terms per row)) rather than proportional to IN_WIDTH.
  for (genvar j = 0; j < W; j++) begin : g_bit
    assign crc_o[j] = ^(terms & MASK[j*TERMS +: TERMS]);
  end

endmodule

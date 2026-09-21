// -----------------------------------------------------------------------------
// ultra_sd_crc7
//   Purpose      : L1. Purely combinational CRC7 for the CMD line, as a flat XOR
//                  matrix. IN_WIDTH message bits are folded in ONE gate level of
//                  AND-mask plus one balanced XOR tree per output bit -- not a
//                  chain of IN_WIDTH shift-and-reduce stages. All 7 output bits
//                  are computed in parallel and independently, so the whole
//                  40-bit command CRC costs one XOR tree deep, not 40.
//   Clock domain : none -- combinational. The remainder register lives in the
//                  caller (ultra_sd_cmd / ultra_sd_line), which owns the clear
//                  and enable policy.
//   Reset scheme : none (no state)
//   Implements   : Spec Appendix A Table A-3 (x^7 + x^3 + 1, MSB first over the
//                  40 command bits and over the corresponding response field)
// -----------------------------------------------------------------------------
module ultra_sd_crc7
  import ultra_sd_pkg::*;
#(
  // Message bits folded per evaluation. 1 = one bit per SD clock;
  // CMD_CRC7_BITS = the whole command in a single cycle. Both are one XOR tree.
  parameter int unsigned IN_WIDTH = 1,
  parameter logic [CRC7_W-1:0] POLY = CRC7_POLY
) (
  // Running remainder in. Drive CRC7_INIT at the start of a message.
  input  logic [CRC7_W-1:0]   crc_i,
  // Message bits, MSB first: data_i[IN_WIDTH-1] is the earliest bit.
  input  logic [IN_WIDTH-1:0] data_i,
  // Remainder after all IN_WIDTH bits have been folded in.
  output logic [CRC7_W-1:0]   crc_o
);
  localparam int unsigned W     = CRC7_W;
  localparam int unsigned TERMS = W + IN_WIDTH; // the {crc_i, data_i} term vector

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
    for (int unsigned k = 0; k < TERMS; k++) begin
      if (k < IN_WIDTH) begin
        acc = {W{1'b0}};              // basis vector on data_i[k]
        d   = {{IN_WIDTH-1{1'b0}}, 1'b1} << k;
      end else begin
        acc = {{W-1{1'b0}}, 1'b1} << (k - IN_WIDTH); // basis on crc_i[k-IN_WIDTH]
        d   = {IN_WIDTH{1'b0}};
      end
      for (int unsigned i = IN_WIDTH; i > 0; i--) begin
        feedback = acc[W-1] ^ d[i-1];
        acc      = {acc[W-2:0], 1'b0} ^ (feedback ? POLY : {W{1'b0}});
      end
      for (int unsigned j = 0; j < W; j++) begin
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

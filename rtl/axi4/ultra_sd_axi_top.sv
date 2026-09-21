// -----------------------------------------------------------------------------
// ultra_sd_axi
//   Purpose      : L4. AXI4-Lite slave register file (Table 5-1), AXI4-Stream master/slave
//                  adapters and interrupt logic. Contains no SD protocol
//                  knowledge and no command opcodes (Table 4-1).
//   Clock domain : clk (system clock)
//   Reset scheme : rst_n, async assert / sync deassert
//   Implements   : Spec Sections 5.3 (register map), 5.4 (statistics counters),
//                  R-IF-1 .. R-IF-12
// -----------------------------------------------------------------------------
module ultra_sd_axi
  import ultra_sd_pkg::*;
#(
  parameter int unsigned DATA_W = 32
) (
  input logic clk,
  input logic rst_n
  // TODO: AXI4-Lite channels, AXI-Stream adapters, L3 block-layer handshake,
  //       statistics counter inputs (SD-clock counts, R-IF-11), irq.
);
endmodule

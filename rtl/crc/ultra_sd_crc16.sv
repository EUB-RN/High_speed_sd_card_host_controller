

module ultra_sd_crc16
  import ultra_sd_pkg::*;
#(

  parameter int IN_WIDTH = 1,
  parameter logic [CRC16_W-1:0] POLY = CRC16_POLY
) (

  input  logic [CRC16_W-1:0]  crc_i,

  input  logic [IN_WIDTH-1:0] data_i,

  output logic [CRC16_W-1:0]  crc_o
);
  localparam int W     = CRC16_W;
  localparam int TERMS = W + IN_WIDTH;

  function automatic logic [W*TERMS-1:0] build_mask();
    logic [W*TERMS-1:0] m;
    logic [W-1:0]       acc;
    logic [IN_WIDTH-1:0] d;
    logic               feedback;
    m = {(W*TERMS){1'b0}};
    for (int k = 0; k < TERMS; k++) begin
      if (k < IN_WIDTH) begin
        acc = {W{1'b0}};
        d   = {{IN_WIDTH-1{1'b0}}, 1'b1} << k;
      end else begin
        acc = {{W-1{1'b0}}, 1'b1} << (k - IN_WIDTH);
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

  logic [TERMS-1:0] terms;
  assign terms = {crc_i, data_i};

  for (genvar j = 0; j < W; j++) begin : g_bit
    assign crc_o[j] = ^(terms & MASK[j*TERMS +: TERMS]);
  end

endmodule

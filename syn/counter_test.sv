
module counter_test(
  input logic clk, rst_n, en, stat_clear,
  output logic [31:0] cnt
);
  logic cnt_rst_n;
  assign cnt_rst_n = rst_n & ~stat_clear;

  always_ff @(posedge clk or negedge cnt_rst_n) begin
    if (!cnt_rst_n) begin
      cnt <= '0;
    end else if (en && (cnt != '1)) begin
      cnt <= cnt + 32'd1;
    end
  end
endmodule

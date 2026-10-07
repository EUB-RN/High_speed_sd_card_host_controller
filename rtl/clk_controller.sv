

module clk_controller
  import ultra_sd_pkg::*;
(

  input  logic                   clk_i,

  input  logic                   rst_n,

  input  logic [CFG_CLK_W-1:0]   cmd_div_i,

  input  logic [CFG_CLK_W-1:0]   line_div_i,

  output logic                   cmd_clk_o,
  output logic                   line_clk_o
);

  localparam int HALF_W = CFG_CLK_W - 1;

  localparam int CH_CMD  = 0;
  localparam int CH_LINE = 1;

  logic [1:0][CFG_CLK_W-1:0] div_i;

  assign div_i[CH_CMD]  = cmd_div_i;
  assign div_i[CH_LINE] = line_div_i;

  logic [1:0][HALF_W-1:0] half_s;

  logic [1:0][HALF_W-1:0] half_cnt;
  logic [1:0][HALF_W-1:0] half_q;
  logic [1:0]              clk_q;

  for (genvar ch = 0; ch < 2; ch++) begin : g_ch

    logic half_done;
    assign half_done = (half_cnt[ch] == '0);

    logic period_start;
    assign period_start = half_done & ~clk_q[ch];

    always_ff @(posedge clk_i or negedge rst_n) begin
      if (!rst_n) begin

        half_s  [ch] <= '0;
        half_cnt[ch] <= '0;
        half_q  [ch] <= '0;
        clk_q   [ch] <= 1'b0;
      end else begin

        if (div_i[ch] < CFG_CLK_W'(2)) begin
          half_s[ch] <= HALF_W'(0);
        end else begin
          half_s[ch] <= div_i[ch][CFG_CLK_W-1:1] - HALF_W'(1);
        end

        if (half_done) begin
          if (period_start) begin
            half_cnt[ch] <= half_s[ch];
            half_q  [ch] <= half_s[ch];
            clk_q   [ch] <= 1'b1;
          end else begin
            half_cnt[ch] <= half_q[ch];
            clk_q   [ch] <= 1'b0;
          end
        end else begin
          half_cnt[ch] <= half_cnt[ch] - HALF_W'(1);
        end
      end
    end
  end

  assign cmd_clk_o  = clk_q[CH_CMD];
  assign line_clk_o = clk_q[CH_LINE];

endmodule

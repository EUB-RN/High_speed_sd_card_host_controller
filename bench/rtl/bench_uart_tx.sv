// -----------------------------------------------------------------------------
// bench_uart_tx
//   Purpose      : 8N1 transmitter, one byte at a time. The only way a number
//                  gets off the board, so it is deliberately the dullest module
//                  here: no FIFO, no flow control, no parity options.
//
//                  The report engine upstream is slower than this is, by orders
//                  of magnitude -- it spends dozens of cycles deciding on each
//                  character -- so a FIFO would buy nothing. `ready` going low
//                  for one character time is the whole backpressure story.
//
//   Clock domain : clk only. The baud divisor is a parameter rather than a
//                  frequency, so this module never has to know what clk is.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module bench_uart_tx #(
  // clk cycles per bit. 99 MHz / 115200 = 859.
  parameter int CLKS_PER_BIT = 859
) (
  input  logic       clk,
  input  logic       rst_n,

  input  logic [7:0] data_i,
  input  logic       valid_i,
  output logic       ready_o,    // 1 = idle, a byte is taken this cycle

  output logic       tx_o
);

  localparam int DIV_W = $clog2(CLKS_PER_BIT);
  localparam int BIT_W = 4;      // start + 8 data + stop = 10 bit times

  logic [DIV_W-1:0] div_q;
  logic [BIT_W-1:0] bit_q;
  logic [9:0]       sh_q;        // {stop, data[7:0], start}, shifted right
  logic             busy_q;

  assign ready_o = !busy_q;

  // Line idles high; the shift register's LSB is on the wire so the start bit
  // falls out first and the trailing ones hold the line up after the stop bit.
  assign tx_o = busy_q ? sh_q[0] : 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_q  <= '0;
      bit_q  <= '0;
      sh_q   <= '1;
      busy_q <= 1'b0;
    end else if (!busy_q) begin
      if (valid_i) begin
        sh_q   <= {1'b1, data_i, 1'b0};
        div_q  <= DIV_W'(CLKS_PER_BIT - 1);
        bit_q  <= BIT_W'(10);
        busy_q <= 1'b1;
      end
    end else if (div_q != '0) begin
      div_q <= div_q - DIV_W'(1);
    end else begin
      div_q <= DIV_W'(CLKS_PER_BIT - 1);
      sh_q  <= {1'b1, sh_q[9:1]};
      if (bit_q == BIT_W'(1)) busy_q <= 1'b0;
      else                    bit_q  <= bit_q - BIT_W'(1);
    end
  end

endmodule

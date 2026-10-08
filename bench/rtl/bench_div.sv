// -----------------------------------------------------------------------------
// bench_div
//   Purpose      : 64-bit / 32-bit unsigned integer division, one bit per cycle.
//                  Exists so the board can print Mbit/s and efficiency directly
//                  instead of printing raw counters for a human to divide. A
//                  number you have to post-process is a number you will
//                  mis-process at 2 a.m. during bring-up.
//
//                  64 bits wide on the numerator because the rate formula is
//                  payload_bits * clk_MHz, and 64 MB of payload is already
//                  5.4e8 bits: times 99, times 10 for one decimal place, is 5e11
//                  and needs 39 bits. 32-bit arithmetic would silently wrap and
//                  report a plausible wrong rate, which is the worst failure
//                  mode a measurement tool has.
//
//                  Restoring division, 64 iterations, ~0.65 us at 99 MHz. It
//                  runs only while the report is being printed, so the cost is
//                  invisible next to a 115200-baud UART.
//
//   Clock domain : clk only.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module bench_div (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        start_i,
  input  logic [63:0] num_i,
  input  logic [31:0] den_i,

  output logic        busy_o,
  output logic        done_o,      // single-cycle pulse
  output logic [31:0] quot_o       // low 32 bits; saturates rather than wraps
);

  logic [63:0] num_q;
  logic [31:0] den_q;
  logic [63:0] quot_q;
  logic [31:0] rem_q;              // always < den, so it never needs 33 bits
  logic [6:0]  cnt_q;              // 64 .. 0
  logic        busy_q;
  logic        done_q;

  // One bit wider than the remainder: this is the shifted value BEFORE the
  // conditional subtract, and that is the only place the extra bit exists.
  logic [32:0] rem_shift;
  logic        rem_ge;

  assign rem_shift = {rem_q, num_q[63]};
  assign rem_ge    = (rem_shift >= {1'b0, den_q});

  assign busy_o = busy_q;
  assign done_o = done_q;
  // A quotient that does not fit is a broken measurement, not a wrapped one:
  // clamp so the printed value is obviously wrong rather than subtly wrong.
  assign quot_o = (quot_q[63:32] != '0) ? 32'hffff_ffff : quot_q[31:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      num_q  <= '0;
      den_q  <= '0;
      quot_q <= '0;
      rem_q  <= '0;
      cnt_q  <= '0;
      busy_q <= 1'b0;
      done_q <= 1'b0;
    end else begin
      done_q <= 1'b0;

      if (start_i && !busy_q) begin
        num_q  <= num_i;
        // Divide by zero would spin; answer 0 and say so by finishing at once.
        den_q  <= den_i;
        quot_q <= '0;
        rem_q  <= '0;
        cnt_q  <= 7'd64;
        busy_q <= (den_i != '0);
        done_q <= (den_i == '0);
      end else if (busy_q) begin
        num_q  <= {num_q[62:0], 1'b0};
        quot_q <= {quot_q[62:0], rem_ge};
        rem_q  <= 32'(rem_ge ? (rem_shift - {1'b0, den_q}) : rem_shift);
        if (cnt_q == 7'd1) begin
          busy_q <= 1'b0;
          done_q <= 1'b1;
        end
        cnt_q <= cnt_q - 7'd1;
      end
    end
  end

endmodule

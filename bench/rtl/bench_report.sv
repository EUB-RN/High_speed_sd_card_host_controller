// -----------------------------------------------------------------------------
// bench_report
//   Purpose      : Turns a table of (8-character label, 32-bit value) pairs into
//                  lines of ASCII on the UART:
//
//                      RD_Mbx10 = 1783
//                      RD_EFFpm = 901
//
//                  The table itself lives in bench_core, because that is where
//                  the values are; this module only walks it. idx_o selects a
//                  row and label_i / value_i are expected to be a combinational
//                  function of it, so adding a field upstream costs one case
//                  branch and nothing here.
//
//   DECIMAL, NOT HEX
//
//                  Hex would be half the logic. It would also mean reading
//                  "0x6F7" off a terminal and converting it by hand at the exact
//                  moment you are trying to decide whether a change helped --
//                  which is when transcription errors happen. Ten digits of
//                  decimal cost one 4-bit comparator and a table of powers of
//                  ten, and the leading zeros are suppressed so the output reads
//                  like a number rather than a register dump.
//
//                  Conversion is successive subtraction, most significant digit
//                  first: for each power of ten, subtract while it fits and
//                  count. At most 9 subtractions per digit, 10 digits, so under
//                  100 cycles per number -- against roughly 87 microseconds per
//                  character at 115200 baud, the arithmetic is free.
//
//   Clock domain : clk only.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module bench_report #(
  parameter int UART_CLKS_PER_BIT = 859
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        start_i,       // single-cycle pulse
  input  logic [7:0]  nfields_i,

  output logic [7:0]  idx_o,         // row being printed
  input  logic [63:0] label_i,       // 8 ASCII characters, MSB first
  input  logic [31:0] value_i,

  output logic        done_o,        // single-cycle pulse
  output logic        uart_tx_o
);

  // 10^9 down to 10^0: digit 0 is the most significant, digit 9 the units. A
  // function rather than an array because an unpacked-array localparam is the
  // kind of thing that parses differently in every simulator, and this costs the
  // same ten constants either way.
  function automatic logic [31:0] pow10(input logic [3:0] d);
    case (d)
      4'd0:    pow10 = 32'd1_000_000_000;
      4'd1:    pow10 = 32'd100_000_000;
      4'd2:    pow10 = 32'd10_000_000;
      4'd3:    pow10 = 32'd1_000_000;
      4'd4:    pow10 = 32'd100_000;
      4'd5:    pow10 = 32'd10_000;
      4'd6:    pow10 = 32'd1_000;
      4'd7:    pow10 = 32'd100;
      4'd8:    pow10 = 32'd10;
      default: pow10 = 32'd1;
    endcase
  endfunction

  typedef enum logic [2:0] {
    R_IDLE,
    R_LABEL,     // the 8 label characters
    R_SEP,       // " = "
    R_DIGIT,     // successive subtraction, one digit at a time
    R_EOL,       // CR LF
    R_NEXT,
    R_DONE
  } state_e;

  state_e      st_q;
  logic [7:0]  idx_q;
  logic [3:0]  chr_q;        // position inside the label / separator / eol
  logic [3:0]  dig_q;        // which power of ten
  // Ondaki kuvvet KAYITLI tutulur. Aksi halde dig_q -> on yollu mux ->
  // 32-bit karsilastirici -> dig_q CE tek bir kombinasyonel yol olur ve
  // sys_clk kritik yolu budur (timing raporu: u_rep/dig_q_*/CE).
  logic [31:0] pow_q;
  logic [3:0]  cnt_q;        // value of the digit being built
  logic [31:0] rem_q;        // what is left of the value
  logic        lead_q;       // still in leading zeros

  logic [7:0]  tx_data;
  logic        tx_valid;
  logic        tx_ready;

  bench_uart_tx #(.CLKS_PER_BIT (UART_CLKS_PER_BIT)) u_tx (
    .clk, .rst_n,
    .data_i  (tx_data),
    .valid_i (tx_valid),
    .ready_o (tx_ready),
    .tx_o    (uart_tx_o)
  );

  assign idx_o = idx_q;

  // The separator and the line ending as small literals rather than magic bytes.
  localparam logic [7:0] CH_SP = 8'h20;
  localparam logic [7:0] CH_EQ = 8'h3d;
  localparam logic [7:0] CH_CR = 8'h0d;
  localparam logic [7:0] CH_LF = 8'h0a;

  // A character is offered whenever one is pending and the UART is free; the
  // state machine below advances on the cycle it is taken.
  logic take;
  assign take = tx_valid && tx_ready;

  always_comb begin
    tx_valid = 1'b0;
    tx_data  = CH_SP;
    case (st_q)
      R_LABEL: begin
        tx_valid = 1'b1;
        // chr_q 0 is the leftmost character, so index down from the top byte.
        tx_data  = label_i[(7 - int'(chr_q)) * 8 +: 8];
      end
      R_SEP: begin
        tx_valid = 1'b1;
        tx_data  = (chr_q == 4'd0) ? CH_SP : (chr_q == 4'd1) ? CH_EQ : CH_SP;
      end
      R_DIGIT: begin
        // Only emitted once the digit is finished: see the sequential block.
        tx_valid = (rem_q < pow_q) &&
                   (!lead_q || (cnt_q != 4'd0) || (dig_q == 4'd9));
        tx_data  = 8'h30 + 8'(cnt_q);
      end
      R_EOL: begin
        tx_valid = 1'b1;
        tx_data  = (chr_q == 4'd0) ? CH_CR : CH_LF;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q   <= R_IDLE;
      idx_q  <= '0;
      chr_q  <= '0;
      dig_q  <= '0;
      pow_q  <= pow10(4'd0);
      cnt_q  <= '0;
      rem_q  <= '0;
      lead_q <= 1'b1;
      done_o <= 1'b0;
    end else begin
      done_o <= 1'b0;

      case (st_q)
        R_IDLE: begin
          if (start_i) begin
            idx_q <= '0;
            chr_q <= '0;
            st_q  <= R_LABEL;
          end
        end

        R_LABEL: begin
          if (take) begin
            if (chr_q == 4'd7) begin
              chr_q <= '0;
              st_q  <= R_SEP;
            end else begin
              chr_q <= chr_q + 4'd1;
            end
          end
        end

        R_SEP: begin
          if (take) begin
            if (chr_q == 4'd2) begin
              // Latch the value here: it is stable for the whole row, and
              // latching it means the upstream mux is only sampled once.
              rem_q  <= value_i;
              dig_q  <= '0;
              pow_q  <= pow10(4'd0);
              cnt_q  <= '0;
              lead_q <= 1'b1;
              chr_q  <= '0;
              st_q   <= R_DIGIT;
            end else begin
              chr_q <= chr_q + 4'd1;
            end
          end
        end

        // Two things happen in this state, never in the same cycle: either the
        // remainder is still big enough to subtract, or the digit is complete
        // and waiting to be taken by the UART.
        R_DIGIT: begin
          if (rem_q >= pow_q) begin
            rem_q <= rem_q - pow_q;
            cnt_q <= cnt_q + 4'd1;
          end else if (take) begin
            lead_q <= 1'b0;
            if (dig_q == 4'd9) begin
              chr_q <= '0;
              st_q  <= R_EOL;
            end else begin
              dig_q <= dig_q + 4'd1;
              pow_q <= pow10(dig_q + 4'd1);
              cnt_q <= '0;
            end
          end else if (lead_q && (cnt_q == 4'd0) && (dig_q != 4'd9)) begin
            // Leading zero: skip it without spending a character time.
            dig_q <= dig_q + 4'd1;
            pow_q <= pow10(dig_q + 4'd1);
          end
        end

        R_EOL: begin
          if (take) begin
            if (chr_q == 4'd1) st_q  <= R_NEXT;
            else               chr_q <= chr_q + 4'd1;
          end
        end

        R_NEXT: begin
          if (idx_q + 8'd1 >= nfields_i) begin
            done_o <= 1'b1;
            st_q   <= R_DONE;
          end else begin
            idx_q <= idx_q + 8'd1;
            chr_q <= '0;
            st_q  <= R_LABEL;
          end
        end

        R_DONE: if (start_i) begin
          idx_q <= '0;
          chr_q <= '0;
          st_q  <= R_LABEL;
        end

        default: st_q <= R_IDLE;
      endcase
    end
  end

endmodule

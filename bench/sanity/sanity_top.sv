// sanity_top -- a life sign, and nothing else.
//
// Built when the benchmark bitstream loaded cleanly and then said nothing at
// all. With one unknown (does the board talk?) and four candidate causes (pin,
// baud, PLL, the design), the only way forward is a bitstream that removes
// three of them. This one uses the same oscillator pin, the same PLL settings,
// the same baud divisor and the same UART transmitter as the benchmark, and
// contains no SD logic whatsoever.
//
//   prints   -> clock, PLL, pin M11, baud and the host reader are all good,
//               so the fault is inside the core or the benchmark sequencer
//   silent   -> the fault is below all of that and the benchmark was never
//               the thing to debug
//
// LED[3] blinks at ~1.5 Hz off the raw 27 MHz input, BEFORE the PLL, so it is a
// life sign even if the PLL never locks. LED[0] shows pll_lock directly. That
// pair distinguishes "no configuration" from "configured but no system clock".
module sanity_top (
  input  logic       clk27,
  output logic       uart_tx,
  output logic [3:0] led
);

  localparam int UART_CLKS_PER_BIT = 859;   // 99e6 / 115200
  localparam int MSG_LEN           = 16;

  logic clk, pll_lock;

  // ---- raw-input heartbeat, independent of the PLL --------------------------
  logic [24:0] raw_cnt_q;
  always_ff @(posedge clk27) raw_cnt_q <= raw_cnt_q + 25'd1;

  // ---- same PLL as bench_top: 27 * 33 / 9 = 99 MHz --------------------------
  rPLL u_pll (
    .CLKOUT (clk), .LOCK (pll_lock), .CLKOUTP (), .CLKOUTD (), .CLKOUTD3 (),
    .RESET (1'b0), .RESET_P (1'b0), .CLKIN (clk27), .CLKFB (1'b0),
    .FBDSEL (6'b0), .IDSEL (6'b0), .ODSEL (6'b0), .PSDA (4'b0),
    .DUTYDA (4'b0), .FDLY (4'b0)
  );
  defparam u_pll.FCLKIN           = "27";
  defparam u_pll.DEVICE           = "GW2A-18C";
  defparam u_pll.DYN_IDIV_SEL     = "false";
  defparam u_pll.IDIV_SEL         = 8;
  defparam u_pll.DYN_FBDIV_SEL    = "false";
  defparam u_pll.FBDIV_SEL        = 32;
  defparam u_pll.DYN_ODIV_SEL     = "false";
  defparam u_pll.ODIV_SEL         = 8;
  defparam u_pll.PSDA_SEL         = "0000";
  defparam u_pll.DYN_DA_EN        = "false";
  defparam u_pll.DUTYDA_SEL       = "1000";
  defparam u_pll.CLKOUT_FT_DIR    = 1'b1;
  defparam u_pll.CLKOUTP_FT_DIR   = 1'b1;
  defparam u_pll.CLKOUT_DLY_STEP  = 0;
  defparam u_pll.CLKOUTP_DLY_STEP = 0;
  defparam u_pll.CLKFB_SEL        = "internal";
  defparam u_pll.CLKOUT_BYPASS    = "false";
  defparam u_pll.CLKOUTP_BYPASS   = "false";
  defparam u_pll.CLKOUTD_BYPASS   = "false";
  defparam u_pll.DYN_SDIV_SEL     = 2;
  defparam u_pll.CLKOUTD_SRC      = "CLKOUT";
  defparam u_pll.CLKOUTD3_SRC     = "CLKOUT";

  // ---- reset, same shape as bench_top --------------------------------------
  logic [10:0] rst_cnt_q;
  logic        rst_n;
  always_ff @(posedge clk) begin
    if (!pll_lock)                  rst_cnt_q <= '0;
    else if (rst_cnt_q != 11'd1024) rst_cnt_q <= rst_cnt_q + 11'd1;
  end
  assign rst_n = (rst_cnt_q == 11'd1024);

  // ---- "SANITY OK nnnn\r\n" over and over ----------------------------------
  // The counter in the message proves the stream is live rather than one frame
  // repeated by a confused receiver.
  logic [7:0]  msg [MSG_LEN];
  logic [15:0] seq_q;

  function automatic logic [7:0] hex4(input logic [3:0] n);
    hex4 = (n < 4'd10) ? (8'h30 + 8'(n)) : (8'h41 + 8'(n) - 8'd10);
  endfunction

  always_comb begin
    msg[0]  = "S"; msg[1]  = "A"; msg[2]  = "N"; msg[3]  = "I";
    msg[4]  = "T"; msg[5]  = "Y"; msg[6]  = " "; msg[7]  = "O";
    msg[8]  = "K"; msg[9]  = " ";
    msg[10] = hex4(seq_q[15:12]);
    msg[11] = hex4(seq_q[11:8]);
    msg[12] = hex4(seq_q[7:4]);
    msg[13] = hex4(seq_q[3:0]);
    msg[14] = 8'h0D;
    msg[15] = 8'h0A;
  end

  logic [4:0]  idx_q;
  logic [23:0] gap_q;
  logic        tx_valid, tx_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      idx_q    <= '0;
      gap_q    <= '0;
      seq_q    <= '0;
      tx_valid <= 1'b0;
    end else begin
      tx_valid <= 1'b0;
      if (idx_q < 5'(MSG_LEN)) begin
        if (tx_ready && !tx_valid) begin
          tx_valid <= 1'b1;
          idx_q    <= idx_q + 5'd1;
        end
      end else begin
        // ~170 ms of quiet between messages, so the stream is readable and the
        // host reader's idle timeout never trips.
        gap_q <= gap_q + 24'd1;
        if (gap_q == 24'hFF_FFFF) begin
          idx_q <= '0;
          seq_q <= seq_q + 16'd1;
        end
      end
    end
  end

  bench_uart_tx #(.CLKS_PER_BIT (UART_CLKS_PER_BIT)) u_tx (
    .clk     (clk),
    .rst_n   (rst_n),
    .valid_i (tx_valid),
    .data_i  (msg[idx_q[3:0]]),
    .ready_o (tx_ready),
    .tx_o    (uart_tx)
  );

  assign led[0] = pll_lock;        // PLL locked
  assign led[1] = rst_n;           // reset released
  assign led[2] = tx_valid;        // UART actually being fed
  assign led[3] = raw_cnt_q[24];   // ~1.5 Hz off the 27 MHz pin, pre-PLL

endmodule

`timescale 1ns/1ps

module tb_crc16;
  import ultra_sd_pkg::*;

  logic [15:0] crc_i;
  logic [71:0] data_i;
  logic [15:0] crc_o;
  int checks;
  int failures;

  ultra_sd_crc16 #(.IN_WIDTH(72)) dut (
    .crc_i(crc_i), .data_i(data_i), .crc_o(crc_o)
  );

  function automatic logic [15:0] reference_crc16(
    input logic [15:0] initial_crc,
    input logic [71:0] value
  );
    logic [15:0] crc;
    logic feedback;
    crc = initial_crc;
    for (int i = 71; i >= 0; i--) begin
      feedback = crc[15] ^ value[i];
      crc = {crc[14:0], 1'b0};
      if (feedback) crc ^= 16'h1021;
    end
    return crc;
  endfunction

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin
      failures++;
      $display("FAIL: %s", message);
    end
  endtask

  initial begin
    checks = 0;
    failures = 0;
    crc_i = 16'h0000;
    data_i = 72'h313233343536373839; // ASCII "123456789"
    #1;
    check(crc_o == 16'h31c3, "CRC-16/XMODEM known-answer vector");
    check(crc_o == reference_crc16(crc_i, data_i), "known vector reference mismatch");

    for (int n = 0; n < 100; n++) begin
      data_i = {$urandom, $urandom, $urandom};
      crc_i = $urandom;
      #1;
      check(crc_o == reference_crc16(crc_i, data_i),
            "random CRC16 matrix/reference mismatch");
    end

    if (failures) begin
      $display("tb_crc16: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_crc16: PASSED (%0d checks)", checks);
    $finish;
  end
endmodule

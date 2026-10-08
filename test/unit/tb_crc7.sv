`timescale 1ns/1ps

module tb_crc7;
  import ultra_sd_pkg::*;

  logic [6:0]  crc_i;
  logic [39:0] data_i;
  logic [6:0]  crc_o;
  int checks;
  int failures;

  ultra_sd_crc7 #(.IN_WIDTH(40)) dut (
    .crc_i(crc_i), .data_i(data_i), .crc_o(crc_o)
  );

  function automatic logic [6:0] reference_crc7(input logic [39:0] value);
    logic [6:0] crc;
    logic feedback;
    crc = '0;
    for (int i = 39; i >= 0; i--) begin
      feedback = crc[6] ^ value[i];
      crc = {crc[5:0], 1'b0};
      if (feedback) crc ^= 7'h09;
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
    crc_i = '0;

    // SD command frames: transmitted CRC byte is {crc7, 1'b1}.
    data_i = 40'h40_00000000; #1;
    check(crc_o == 7'h4a, "CMD0 CRC7 must be 0x4a (frame byte 0x95)");
    check(crc_o == reference_crc7(data_i), "CMD0 matrix/reference mismatch");

    data_i = 40'h48_000001aa; #1;
    check(crc_o == 7'h43, "CMD8 CRC7 must be 0x43 (frame byte 0x87)");
    check(crc_o == reference_crc7(data_i), "CMD8 matrix/reference mismatch");

    for (int n = 0; n < 100; n++) begin
      data_i = {$urandom, $urandom} & 40'hff_ffff_ffff;
      crc_i = $urandom;
      #1;
      // Reference with a non-zero incoming remainder.
      begin
        logic [6:0] ref_crc;
        logic feedback;
        ref_crc = crc_i;
        for (int i = 39; i >= 0; i--) begin
          feedback = ref_crc[6] ^ data_i[i];
          ref_crc = {ref_crc[5:0], 1'b0};
          if (feedback) ref_crc ^= 7'h09;
        end
        check(crc_o == ref_crc, "random CRC7 matrix/reference mismatch");
      end
    end

    if (failures) begin
      $display("tb_crc7: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_crc7: PASSED (%0d checks)", checks);
    $finish;
  end
endmodule

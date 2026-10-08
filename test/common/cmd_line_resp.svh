// -----------------------------------------------------------------------------
// cmd_line_resp.svh
//   Davranissal kart tarafi: CMD hattindan komut cercevesi yakalar ve yanit
//   cercevesi surer. ultra_sd_cmd artik baslatma merdivenini de iceriyor, yani
//   merdivenin istegi modul icinde kaliyor ve testler onu GERCEK CMD hatti
//   uzerinden yanitliyor -- tb_init_cmd_stack'in hep yaptigi sey.
//
//   Yakalanan cercevenin argumani cap_arg'a yazilir: merdivenin urettigi
//   argumani (CMD55'in RCA'si, ACMD6'nin bus-width'i, CMD6'nin switch'i) ic
//   sinyale bakmadan, telden dogrulamak icin.
//
//   Bekledigi isimler: cmd_clk, cmd_oe, cmd_out, cmd_in, cap_arg, check()
// -----------------------------------------------------------------------------

function automatic logic [6:0] crc7_40(input logic [39:0] value);
  logic [6:0] crc; logic fb;
  crc = 0;
  for (int i = 39; i >= 0; i--) begin
    fb = crc[6] ^ value[i];
    crc = {crc[5:0], 1'b0} ^ (fb ? 7'h09 : 7'h00);
  end
  return crc;
endfunction

function automatic logic [6:0] crc7_120(input logic [119:0] value);
  logic [6:0] crc; logic fb;
  crc = 0;
  for (int i = 119; i >= 0; i--) begin
    fb = crc[6] ^ value[i];
    crc = {crc[5:0], 1'b0} ^ (fb ? 7'h09 : 7'h00);
  end
  return crc;
endfunction

// Hattan 48 bitlik komut cercevesini toplar ve indeksini dogrular.
task automatic capture_command(input logic [5:0] expected_index);
  logic [47:0] frame;
  int n, timeout;
  frame = 0; n = 0; timeout = 0;
  while (n < 48 && timeout < 4000) begin
    @(negedge cmd_clk); #1; timeout++;
    if (cmd_oe) begin frame = {frame[46:0], cmd_out}; n++; end
  end
  check(n == 48, "card saw a complete command frame");
  check(frame[45:40] == expected_index,
        $sformatf("wire command expected CMD%0d got CMD%0d",
                  expected_index, frame[45:40]));
  check(frame[0] && frame[7:1] == crc7_40(frame[47:8]),
        "host command CRC7 and stop bit");
  cap_arg = frame[39:8];
endtask

// Komutu yakalar ama HIC yanit vermez: komut motorunun timeout yolunu surer.
task automatic capture_and_drop(input logic [5:0] expected_index);
  capture_command(expected_index);
  cmd_in = 1'b1;
endtask

task automatic send_short(input logic [5:0] response_index,
                          input logic [31:0] argument,
                          input logic crc_meaningful);
  logic [47:0] frame;
  logic [39:0] header;
  header = {1'b0, 1'b0, response_index, argument};
  frame = {header, crc_meaningful ? crc7_40(header) : 7'h7f, 1'b1};
  @(posedge cmd_clk); @(negedge cmd_clk);
  for (int i = 47; i >= 0; i--) begin
    cmd_in = frame[i]; @(posedge cmd_clk); @(negedge cmd_clk);
  end
  cmd_in = 1;
endtask

task automatic send_long(input logic [119:0] content);
  logic [135:0] frame;
  frame = {8'h3f, content, crc7_120(content), 1'b1};
  @(posedge cmd_clk); @(negedge cmd_clk);
  for (int i = 135; i >= 0; i--) begin
    cmd_in = frame[i]; @(posedge cmd_clk); @(negedge cmd_clk);
  end
  cmd_in = 1;
endtask

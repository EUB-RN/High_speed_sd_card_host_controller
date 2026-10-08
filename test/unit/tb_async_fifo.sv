`timescale 1ns/1ps

module tb_async_fifo;
  localparam int DATA_W = 8;
  localparam int DEPTH = 8;

  logic wr_clk = 0, rd_clk = 0;
  logic wr_rst_n, rd_rst_n, wr_en, rd_en;
  logic wr_commit, wr_rewind, rd_commit, rd_rewind;
  logic [DATA_W-1:0] wr_data, rd_data;
  logic wr_full, rd_valid;
  logic [$clog2(DEPTH):0] wr_level, rd_level;
  int checks;
  int failures;

  always #3.5 wr_clk = ~wr_clk;
  always #5.5 rd_clk = ~rd_clk;

  async_fifo #(.DATA_W(DATA_W), .DEPTH(DEPTH)) dut (.*);

  task automatic check(input logic condition, input string message);
    checks++;
    if (!condition) begin failures++; $display("FAIL: %s", message); end
  endtask

  task automatic push(input logic [7:0] value);
    @(negedge wr_clk); wr_data = value; wr_en = 1;
    @(posedge wr_clk); #1;
    @(negedge wr_clk); wr_en = 0;
  endtask

  task automatic wait_valid;
    int timeout;
    timeout = 0;
    while (!rd_valid && timeout < 30) begin @(posedge rd_clk); #1; timeout++; end
    check(rd_valid, "read data became valid before timeout");
  endtask

  task automatic pop_check(input logic [7:0] expected);
    wait_valid();
    check(rd_data == expected,
          $sformatf("FIFO ordering/data expected=0x%02x actual=0x%02x",
                    expected, rd_data));
    @(negedge rd_clk); rd_en = 1;
    @(posedge rd_clk); #1;
    @(negedge rd_clk); rd_en = 0;
  endtask

  initial begin
    checks = 0; failures = 0;
    wr_rst_n = 0; rd_rst_n = 0; wr_en = 0; rd_en = 0; wr_data = 0;
    // Spekulasyon kapali: her yazilan kelime yayinlanir, her okunan serbest
    // kalir -- yani duz FIFO davranisi.
    wr_commit = 1; wr_rewind = 0; rd_commit = 1; rd_rewind = 0;
    repeat (3) @(posedge wr_clk); wr_rst_n = 1;
    repeat (3) @(posedge rd_clk); rd_rst_n = 1;
    repeat (2) @(posedge rd_clk); #1;
    check(!wr_full && !rd_valid && wr_level == 0 && rd_level == 0,
          "empty after reset");

    push(8'h10); push(8'h21); push(8'h32); push(8'h43);
    pop_check(8'h10); pop_check(8'h21); pop_check(8'h32); pop_check(8'h43);
    repeat (4) @(posedge rd_clk); #1;
    check(!rd_valid && rd_level == 0, "empty after draining");

    for (int i = 0; i < DEPTH; i++) push(8'h80 + i);
    begin
      int timeout;
      timeout = 0;
      while (!wr_full && timeout < 20) begin @(posedge wr_clk); #1; timeout++; end
      check(wr_full && wr_level == DEPTH,
            $sformatf("full at capacity: full=%0b write_level=%0d expected=%0d",
                      wr_full, wr_level, DEPTH));
    end
    push(8'hee); // ignored while full
    for (int i = 0; i < DEPTH; i++) pop_check(8'h80 + i);
    repeat (5) @(posedge rd_clk); #1;
    check(!rd_valid, "overflow write was rejected");

    // Underflow request must not fabricate a valid word.
    @(negedge rd_clk); rd_en = 1;
    @(posedge rd_clk); #1;
    @(negedge rd_clk); rd_en = 0;
    repeat (3) @(posedge rd_clk); #1;
    check(!rd_valid && rd_level == 0, "underflow request ignored");

    // -------------------------------------------------------------------------
    // Spekulatif yazma: yayinlanmamis kelimeler okuyucuya GORUNMEZ, geri
    // sarilinca da hic yazilmamis gibi olur (ultra_sd_block'un CRC16 yeniden
    // denemesi buna dayaniyor).
    // -------------------------------------------------------------------------
    wr_commit = 0;
    push(8'ha0); push(8'ha1); push(8'ha2);
    repeat (6) @(posedge rd_clk); #1;
    check(!rd_valid && rd_level == 0, "uncommitted words stay invisible");
    check(wr_level == 3, "uncommitted words still occupy storage");

    @(negedge wr_clk); wr_rewind = 1;
    @(posedge wr_clk); #1;
    @(negedge wr_clk); wr_rewind = 0;
    repeat (6) @(posedge rd_clk); #1;
    check(!rd_valid && wr_level == 0, "rewind drops the uncommitted block");

    push(8'hb0); push(8'hb1);
    wr_commit = 1;
    push(8'hb2);                       // bu kelime uc tanesini de yayinlar
    pop_check(8'hb0); pop_check(8'hb1); pop_check(8'hb2);
    repeat (4) @(posedge rd_clk); #1;
    check(!rd_valid, "commit published exactly the written words");

    // -------------------------------------------------------------------------
    // Spekulatif okuma: tuketilen ama birakilmamis kelimeler geri sarilinca
    // tekrar sunulur (yazma CRC durum token'i olumsuz gelirse boyle olur).
    // -------------------------------------------------------------------------
    push(8'hc0); push(8'hc1); push(8'hc2);
    rd_commit = 0;
    pop_check(8'hc0); pop_check(8'hc1);
    check(wr_level == 3, "writer cannot reclaim uncommitted reads");

    @(negedge rd_clk); rd_rewind = 1;
    @(posedge rd_clk); #1;
    @(negedge rd_clk); rd_rewind = 0;
    rd_commit = 1;
    pop_check(8'hc0); pop_check(8'hc1); pop_check(8'hc2);
    repeat (4) @(posedge rd_clk); #1;
    check(!rd_valid && wr_level == 0, "rewind replayed the whole block");

    if (failures) begin
      $display("tb_async_fifo: FAILED (%0d/%0d)", failures, checks);
      $fatal(1);
    end
    $display("tb_async_fifo: PASSED (%0d checks)", checks);
    $finish;
  end
endmodule

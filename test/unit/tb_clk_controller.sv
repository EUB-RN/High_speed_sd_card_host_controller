// -----------------------------------------------------------------------------
// tb_clk_controller
//   Purpose      : clk_controller icin kendi kendini kontrol eden unit test.
//
//                  Kontrol edilenler:
//                    1. Bolme orani      : cmd_clk_o = clk_i / cmd_div_i,
//                                          line_clk_o = clk_i / line_div_i
//                    2. Oran islemleri   : tek oran asagi yuvarlanir, 2'nin
//                                          altindaki oran 2'ye kirpilir
//                    3. Duty cycle       : yuksek faz = alcak faz (%50)
//                    4. Kanal bagimsizl. : bir kanalin orani
//                                          digerini etkilemez
//                    5. Canli yeniden pr.: calisirken oran degistirmek kisa
//                                          faz uretmez
//                    6. Reset            : rst_n altinda iki saat de ALCAKTA
//                                          park eder, serbest kalinca temiz
//                                          bir periyottan baslar
//
//                  Saat gateleme clk_controller'dan PHY'ye tasinmistir; bu
//                  test yalnizca bolucu sozlesmesini sinar.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Faz olcer. Uretilen saatin yuksek/alcak faz uzunlugunu clk_i cevrimi
// cinsinden olcer ve gorulen en kisa fazi saklar (runt tespiti).
// -----------------------------------------------------------------------------
module phase_chk (
  input logic clk,
  input logic gclk,
  input logic clr   // olcumleri sifirla
);
  int unsigned cnt     = 0;   // mevcut fazda gecen cevrim
  logic        prev    = 1'b0;
  int unsigned last_hi = 0;   // son tamamlanan yuksek faz
  int unsigned last_lo = 0;   // son tamamlanan alcak faz
  int unsigned min_hi  = 32'hFFFF_FFFF;
  int unsigned min_lo  = 32'hFFFF_FFFF;
  int unsigned n_hi    = 0;   // tamamlanan yuksek faz sayisi
  int unsigned n_lo    = 0;
  // clr an itibariyle devam etmekte olan faz yarim olcilur; ilk kenara kadar
  // olcum silahlanmaz, boylece sadece bastan sona gorulen fazlar sayilir.
  logic        arm     = 1'b0;

  always @(posedge clk) begin
    if (clr) begin
      cnt     <= 1;
      prev    <= gclk;
      arm     <= 1'b0;
      last_hi <= 0;
      last_lo <= 0;
      min_hi  <= 32'hFFFF_FFFF;
      min_lo  <= 32'hFFFF_FFFF;
      n_hi    <= 0;
      n_lo    <= 0;
    end else if (gclk !== prev) begin
      if (arm) begin
        if (prev) begin
          last_hi <= cnt;
          n_hi    <= n_hi + 1;
          if (cnt < min_hi) min_hi <= cnt;
        end else begin
          last_lo <= cnt;
          n_lo    <= n_lo + 1;
          if (cnt < min_lo) min_lo <= cnt;
        end
      end else begin
        arm <= 1'b1;        // yarim olculen ilk faz atilir
      end
      cnt  <= 1;
      prev <= gclk;
    end else begin
      cnt <= cnt + 1;
    end
  end
endmodule


module tb_clk_controller;

  logic clk = 1'b0;
  always #5 clk = ~clk;          // 100 MHz

  logic [7:0] cmd_div  = 8'd4;
  logic [7:0] line_div = 8'd8;
  logic       cmd_clk, line_clk;
  logic       clr      = 1'b0;
  logic       rst_n    = 1'b0;

  clk_controller dut (
    .clk_i      (clk),
    .rst_n      (rst_n),
    .cmd_div_i  (cmd_div),
    .line_div_i (line_div),
    .cmd_clk_o  (cmd_clk),
    .line_clk_o (line_clk)
  );

  phase_chk chk_cmd  (.clk(clk), .gclk(cmd_clk),  .clr(clr));
  phase_chk chk_line (.clk(clk), .gclk(line_clk), .clr(clr));

  int unsigned fails = 0;
  int unsigned checks = 0;

  task automatic ok(input string what, input bit cond);
    checks++;
    if (!cond) begin
      fails++;
      $display("  FAIL @%0t : %s", $time, what);
    end
  endtask

  // Beklenen yarim periyot (clk_i cevrimi)
  function automatic int unsigned exp_half(input int unsigned d);
    return (d < 2) ? 1 : (d / 2);
  endfunction

  task automatic restart_meas;
    @(posedge clk); clr <= 1'b1;
    @(posedge clk); clr <= 1'b0;
    @(posedge clk);
  endtask

  // Oran testi: iki kanalin da uzun sure dogru oranda kostugunu dogrula.
  task automatic check_rates(input string tag);
    int unsigned ec, el;
    ec = exp_half(cmd_div);
    el = exp_half(line_div);
    // Yeni oranin devreye girmesi icin bir kac tam periyot bekle.
    repeat (8 * (ec > el ? ec : el) + 16) @(posedge clk);
    restart_meas;
    repeat (8 * (ec > el ? ec : el) + 16) @(posedge clk);

    ok($sformatf("%s: cmd yuksek faz %0d (beklenen %0d)", tag, chk_cmd.last_hi, ec),
       chk_cmd.last_hi == ec);
    ok($sformatf("%s: cmd alcak faz %0d (beklenen %0d)", tag, chk_cmd.last_lo, ec),
       chk_cmd.last_lo == ec);
    ok($sformatf("%s: cmd en kisa yuksek faz %0d (beklenen %0d)", tag, chk_cmd.min_hi, ec),
       chk_cmd.min_hi == ec);
    ok($sformatf("%s: cmd kenar uretildi (%0d)", tag, chk_cmd.n_hi), chk_cmd.n_hi >= 2);

    ok($sformatf("%s: line yuksek faz %0d (beklenen %0d)", tag, chk_line.last_hi, el),
       chk_line.last_hi == el);
    ok($sformatf("%s: line alcak faz %0d (beklenen %0d)", tag, chk_line.last_lo, el),
       chk_line.last_lo == el);
    ok($sformatf("%s: line en kisa yuksek faz %0d (beklenen %0d)", tag, chk_line.min_hi, el),
       chk_line.min_hi == el);
    ok($sformatf("%s: line kenar uretildi (%0d)", tag, chk_line.n_hi), chk_line.n_hi >= 2);
  endtask

  int unsigned i;
  int unsigned hi_before;

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("tb_clk_controller.vcd");
      $dumpvars(0, tb_clk_controller);
    end

    $display("-- 0/3 reset --");
    // rst_n basta 0. Reset altinda iki saat de alcakta park etmeli.
    repeat (40) @(posedge clk);
    ok("reset altinda cmd_clk alcakta",  cmd_clk  === 1'b0);
    ok("reset altinda line_clk alcakta", line_clk === 1'b0);
    restart_meas;
    repeat (40) @(posedge clk);
    ok($sformatf("reset altinda cmd kenari yok (%0d)",  chk_cmd.n_hi),  chk_cmd.n_hi  == 0);
    ok($sformatf("reset altinda line kenari yok (%0d)", chk_line.n_hi), chk_line.n_hi == 0);

    @(negedge clk) rst_n = 1'b1;   // senkron deassert
    restart_meas;
    repeat (64) @(posedge clk);
    ok($sformatf("reset sonrasi cmd basladi (%0d kenar)", chk_cmd.n_hi), chk_cmd.n_hi >= 2);
    ok($sformatf("reset sonrasi line basladi (%0d kenar)", chk_line.n_hi), chk_line.n_hi >= 2);
    ok($sformatf("reset sonrasi cmd ilk fazlar tam (%0d, beklenen %0d)",
                 chk_cmd.min_hi, exp_half(cmd_div)), chk_cmd.min_hi == exp_half(cmd_div));

    // Calisirken asenkron reset: hemen alcaga cekmeli.
    @(posedge clk); #1 rst_n = 1'b0;
    #1 ok("asenkron reset cmd_clk'i hemen alcaga cekti",  cmd_clk  === 1'b0);
    ok("asenkron reset line_clk'i hemen alcaga cekti", line_clk === 1'b0);
    repeat (8) @(posedge clk);
    @(negedge clk) rst_n = 1'b1;
    repeat (8) @(posedge clk);

    $display("-- 1/3 bolme orani ve duty cycle --");
    cmd_div = 8'd4;   line_div = 8'd8;   check_rates("div 4 / 8");
    cmd_div = 8'd10;  line_div = 8'd8;   check_rates("div 10 / 8");   // line degismedi
    cmd_div = 8'd64;  line_div = 8'd2;   check_rates("div 64 / 2");
    cmd_div = 8'd250; line_div = 8'd4;   check_rates("div 250 / 4");  // ~400 kHz

    $display("-- 2/3 tek oran asagi yuvarlanir, kucuk oran kirpilir --");
    cmd_div = 8'd7;   line_div = 8'd9;   check_rates("div 7 / 9");    // -> 6 / 8
    cmd_div = 8'd1;   line_div = 8'd0;   check_rates("div 1 / 0");    // -> 2 / 2
    cmd_div = 8'd3;   line_div = 8'd5;   check_rates("div 3 / 5");    // -> 2 / 4

    $display("-- 3/3 calisirken oran degistirme --");
    cmd_div = 8'd4; line_div = 8'd4;
    repeat (64) @(posedge clk);
    for (i = 0; i < 10; i++) begin
      restart_meas;
      repeat (i) @(posedge clk);
      cmd_div = 8'd16;               // yavasla
      repeat (64) @(posedge clk);
      // Gecis sirasinda hicbir faz eski orandan (2 cevrim) kisa olmamali.
      ok($sformatf("ofset %0d: hizli->yavas gecisinde kisa faz yok (%0d)", i, chk_cmd.min_hi),
         chk_cmd.min_hi >= 2);
      ok($sformatf("ofset %0d: hizli->yavas sonunda oran 8 (%0d)", i, chk_cmd.last_hi),
         chk_cmd.last_hi == 8);
      restart_meas;
      repeat (i) @(posedge clk);
      cmd_div = 8'd4;                // hizlan
      repeat (64) @(posedge clk);
      ok($sformatf("ofset %0d: yavas->hizli sonunda oran 2 (%0d)", i, chk_cmd.last_hi),
         chk_cmd.last_hi == 2);
    end

    $display("");
    if (fails == 0)
      $display("tb_clk_controller: PASS (%0d kontrol)", checks);
    else
      $display("tb_clk_controller: FAIL (%0d/%0d kontrol basarisiz)", fails, checks);
    if (fails != 0) $fatal(1, "tb_clk_controller failed");
    $finish;
  end

  initial begin
    #5_000_000;
    $fatal(1, "tb_clk_controller timeout");
  end

endmodule

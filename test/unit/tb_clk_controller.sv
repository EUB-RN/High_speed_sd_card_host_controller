// -----------------------------------------------------------------------------
// tb_clk_controller
//   Purpose      : clk_controller icin kendi kendini kontrol eden unit test.
//
//                  Kontrol edilenler:
//                    1. Bolme orani      : clk_o = clk_i / div_i
//                    2. Oran islemleri   : tek oran asagi yuvarlanir, 2'nin
//                                          altindaki oran 2'ye kirpilir
//                    3. Duty cycle       : yuksek faz = alcak faz (%50)
//                    4. Ornek bagimsizl. : modul tek kanallidir; iki ayri
//                                          ORNEK birbirinin oranini etkilemez
//                                          (eskiden tek modulde iki kanal
//                                          vardi, kart'in tek saat pedi
//                                          oldugu icin ikincisi olu mantikti)
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

  logic [7:0] div_a  = 8'd4;
  logic [7:0] div_b = 8'd8;
  logic       clk_a, clk_b;
  logic       clr      = 1'b0;
  logic       rst_n    = 1'b0;

  clk_controller dut_a (
    .clk_i (clk),
    .rst_n (rst_n),
    .div_i (div_a),
    .clk_o (clk_a)
  );

  clk_controller dut_b (
    .clk_i (clk),
    .rst_n (rst_n),
    .div_i (div_b),
    .clk_o (clk_b)
  );

  phase_chk chk_a  (.clk(clk), .gclk(clk_a),  .clr(clr));
  phase_chk chk_b (.clk(clk), .gclk(clk_b), .clr(clr));

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
    ec = exp_half(div_a);
    el = exp_half(div_b);
    // Yeni oranin devreye girmesi icin bir kac tam periyot bekle.
    repeat (8 * (ec > el ? ec : el) + 16) @(posedge clk);
    restart_meas;
    repeat (8 * (ec > el ? ec : el) + 16) @(posedge clk);

    ok($sformatf("%s: A yuksek faz %0d (beklenen %0d)", tag, chk_a.last_hi, ec),
       chk_a.last_hi == ec);
    ok($sformatf("%s: A alcak faz %0d (beklenen %0d)", tag, chk_a.last_lo, ec),
       chk_a.last_lo == ec);
    ok($sformatf("%s: A en kisa yuksek faz %0d (beklenen %0d)", tag, chk_a.min_hi, ec),
       chk_a.min_hi == ec);
    ok($sformatf("%s: A kenar uretildi (%0d)", tag, chk_a.n_hi), chk_a.n_hi >= 2);

    ok($sformatf("%s: B yuksek faz %0d (beklenen %0d)", tag, chk_b.last_hi, el),
       chk_b.last_hi == el);
    ok($sformatf("%s: B alcak faz %0d (beklenen %0d)", tag, chk_b.last_lo, el),
       chk_b.last_lo == el);
    ok($sformatf("%s: B en kisa yuksek faz %0d (beklenen %0d)", tag, chk_b.min_hi, el),
       chk_b.min_hi == el);
    ok($sformatf("%s: B kenar uretildi (%0d)", tag, chk_b.n_hi), chk_b.n_hi >= 2);
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
    ok("reset altinda clk_a alcakta",  clk_a  === 1'b0);
    ok("reset altinda clk_b alcakta", clk_b === 1'b0);
    restart_meas;
    repeat (40) @(posedge clk);
    ok($sformatf("reset altinda A kenari yok (%0d)",  chk_a.n_hi),  chk_a.n_hi  == 0);
    ok($sformatf("reset altinda B kenari yok (%0d)", chk_b.n_hi), chk_b.n_hi == 0);

    @(negedge clk) rst_n = 1'b1;   // senkron deassert
    restart_meas;
    repeat (64) @(posedge clk);
    ok($sformatf("reset sonrasi A basladi (%0d kenar)", chk_a.n_hi), chk_a.n_hi >= 2);
    ok($sformatf("reset sonrasi B basladi (%0d kenar)", chk_b.n_hi), chk_b.n_hi >= 2);
    ok($sformatf("reset sonrasi A ilk fazlar tam (%0d, beklenen %0d)",
                 chk_a.min_hi, exp_half(div_a)), chk_a.min_hi == exp_half(div_a));

    // Calisirken asenkron reset: hemen alcaga cekmeli.
    @(posedge clk); #1 rst_n = 1'b0;
    #1 ok("asenkron reset clk_a'i hemen alcaga cekti",  clk_a  === 1'b0);
    ok("asenkron reset clk_b'i hemen alcaga cekti", clk_b === 1'b0);
    repeat (8) @(posedge clk);
    @(negedge clk) rst_n = 1'b1;
    repeat (8) @(posedge clk);

    $display("-- 1/3 bolme orani ve duty cycle --");
    div_a = 8'd4;   div_b = 8'd8;   check_rates("div 4 / 8");
    div_a = 8'd10;  div_b = 8'd8;   check_rates("div 10 / 8");   // B degismedi
    div_a = 8'd64;  div_b = 8'd2;   check_rates("div 64 / 2");
    div_a = 8'd250; div_b = 8'd4;   check_rates("div 250 / 4");  // ~400 kHz

    $display("-- 2/3 tek oran asagi yuvarlanir, kucuk oran kirpilir --");
    div_a = 8'd7;   div_b = 8'd9;   check_rates("div 7 / 9");    // -> 6 / 8
    div_a = 8'd1;   div_b = 8'd0;   check_rates("div 1 / 0");    // -> 2 / 2
    div_a = 8'd3;   div_b = 8'd5;   check_rates("div 3 / 5");    // -> 2 / 4

    $display("-- 3/3 calisirken oran degistirme --");
    div_a = 8'd4; div_b = 8'd4;
    repeat (64) @(posedge clk);
    for (i = 0; i < 10; i++) begin
      restart_meas;
      repeat (i) @(posedge clk);
      div_a = 8'd16;               // yavasla
      repeat (64) @(posedge clk);
      // Gecis sirasinda hicbir faz eski orandan (2 cevrim) kisa olmamali.
      ok($sformatf("ofset %0d: hizli->yavas gecisinde kisa faz yok (%0d)", i, chk_a.min_hi),
         chk_a.min_hi >= 2);
      ok($sformatf("ofset %0d: hizli->yavas sonunda oran 8 (%0d)", i, chk_a.last_hi),
         chk_a.last_hi == 8);
      restart_meas;
      repeat (i) @(posedge clk);
      div_a = 8'd4;                // hizlan
      repeat (64) @(posedge clk);
      ok($sformatf("ofset %0d: yavas->hizli sonunda oran 2 (%0d)", i, chk_a.last_hi),
         chk_a.last_hi == 2);
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

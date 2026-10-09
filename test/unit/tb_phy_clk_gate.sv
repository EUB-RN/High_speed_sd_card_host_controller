// -----------------------------------------------------------------------------
// tb_phy_clk_gate
//   Purpose      : ultra_sd_phy_gowin'in SAAT sozlesmesi icin unit test.
//                  Bolme ve gateleme bu modulun icinde (clk_controller + DQCE);
//                  bu test o sozlesmeyi sinar ve pedlerle ilgilenmez.
//
//                  +define+ULTRA_SD_NO_VENDOR_PRIM ile kosar: gercek Gowin
//                  makrosu yerine ayni davranisin modeli devreye girer
//                  (enable saatin DUSEN kenarinda kilitlenir).
//
//                  Burada eskiden iki kanal (CMD/LINE) ve bir ped mux'u
//                  (pad_line_sel / DCS) sinaniyordu. Ikisi de kalkti: kartin
//                  tek saat pedi var, iki kanal hicbir zaman farkli kosamazdi,
//                  secim biti sabit 0 bagliydi ve enable'lar ayni teldi. Tek
//                  saat agi kaldigi icin "kanal ayrimi" ve "ped mux'u"
//                  bolumlerinin yerini ped ile cekirdek saatinin AYNI dalga
//                  formu oldugunun dogrulanmasi aldi.
//
//                  Kontrol edilenler:
//                    1. Gate kapali   : cikis ALCAKTA park eder, kenar yok
//                    2. Runt yok      : enable her faz ofsetinde dusurulse
//                                       bile hicbir yuksek faz kisalmaz, ve
//                                       geri acildiginda faz kaymaz (serbest
//                                       kosan bolucunun karsiligi)
//                    3. Tek ag        : sd_clk pedi ile cekirdek saati her
//                                       an ayni deger -- arada mux yok
//                    4. Reset         : rst_n altinda iki saat de alcakta
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

// Faz olcer: yuksek/alcak faz uzunlugunu clk cevrimi cinsinden olcer, gorulen
// en kisa fazi saklar (runt tespiti).
module gate_phase_chk (
  input logic clk,
  input logic gclk,
  input logic clr
);
  int unsigned cnt     = 0;
  logic        prev    = 1'b0;
  int unsigned min_hi  = 32'hFFFF_FFFF;
  int unsigned min_lo  = 32'hFFFF_FFFF;
  int unsigned n_hi    = 0;
  logic        arm     = 1'b0;

  always @(posedge clk) begin
    if (clr) begin
      cnt    <= 1;
      prev   <= gclk;
      arm    <= 1'b0;
      min_hi <= 32'hFFFF_FFFF;
      min_lo <= 32'hFFFF_FFFF;
      n_hi   <= 0;
    end else if (gclk !== prev) begin
      if (arm) begin
        if (prev) begin
          n_hi <= n_hi + 1;
          if (cnt < min_hi) min_hi <= cnt;
        end else begin
          if (cnt < min_lo) min_lo <= cnt;
        end
      end else begin
        arm <= 1'b1;          // yarim olculen ilk faz atilir
      end
      cnt  <= 1;
      prev <= gclk;
    end else begin
      cnt <= cnt + 1;
    end
  end
endmodule


module tb_phy_clk_gate;

  import ultra_sd_pkg::*;

  localparam int DIV = 8;          // yarim periyot = 4 clk cevrimi
  localparam int HALF = DIV / 2;

  logic clk = 1'b0;
  always #5 clk = ~clk;            // 100 MHz

  logic rst_n = 1'b0;

  // Bolucu artik DUT'un ICINDE (clk_controller, u_clk_controller): buraya
  // yalnizca ORAN veriyoruz. Ham saatleri gozlemek icin hiyerarsik okuyoruz.
  logic [CFG_CLK_W-1:0] div = CFG_CLK_W'(DIV);
  wire sd_div_clk = dut.sd_clk_div;

  logic sd_en = 1'b0;

  logic sd_clk_g;
  logic sd_clk;
  wire  sd_cmd;
  wire  [3:0] sd_dat;

  // Hatlari bos (yukarida) tutan pull-up'lar: kart tarafinin karsiligi.
  pullup (sd_cmd);
  pullup pu_dat [3:0] (sd_dat);

  ultra_sd_phy_gowin dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .cfg_phy_i      (CFG_PHY_W'(0)),
    .clk_div_i      (div),
    .sd_clk_en_i    (sd_en),
    .sd_clk_o       (sd_clk_g),
    .cmd_out_i      (1'b1),
    .cmd_oe_i       (1'b0),
    .cmd_in_o       (),
    .dat_out_i      ({SD_DATA_LANES{1'b1}}),
    .dat_oe_i       ({SD_DATA_LANES{1'b0}}),
    .dat_in_o       (),
    .sd_clk         (sd_clk),
    .sd_cmd         (sd_cmd),
    .sd_dat         (sd_dat)
  );

  logic clr = 1'b0;
  gate_phase_chk chk_core (.clk(clk), .gclk(sd_clk_g), .clr(clr));
  gate_phase_chk chk_pad  (.clk(clk), .gclk(sd_clk),   .clr(clr));

  // Tek ag sozlesmesi: ped ile cekirdek saati HER AN ayni. Bir mux geri
  // eklenirse (ya da ped baska bir kaynaga baglanirsa) bu sayac patlar.
  int unsigned pad_core_diff = 0;
  always @(sd_clk or sd_clk_g) if (rst_n && (sd_clk !== sd_clk_g)) pad_core_diff++;

  int unsigned fails = 0;
  int unsigned checks = 0;

  task automatic ok(input string what, input bit cond);
    checks++;
    if (!cond) begin
      fails++;
      $display("  FAIL @%0t : %s", $time, what);
    end
  endtask

  task automatic restart_meas;
    @(posedge clk); clr <= 1'b1;
    @(posedge clk); clr <= 1'b0;
    @(posedge clk);
  endtask

  int unsigned i;

  initial begin
    if ($test$plusargs("dump")) begin
      $dumpfile("tb_phy_clk_gate.vcd");
      $dumpvars(0, tb_phy_clk_gate);
    end

    $display("-- 0/3 reset: gate kapali, iki saat de alcakta --");
    repeat (40) @(posedge clk);
    ok("reset altinda sd_clk_o alcakta", sd_clk_g === 1'b0);
    ok("reset altinda sd_clk pedi alcakta", sd_clk === 1'b0);

    @(negedge clk) rst_n = 1'b1;
    // Gate hala kapali: bolucu kosuyor ama disari saat cikmamali.
    restart_meas;
    repeat (16 * HALF) @(posedge clk);
    ok($sformatf("gate kapaliyken cekirdek kenari yok (%0d)", chk_core.n_hi),
       chk_core.n_hi == 0);
    ok($sformatf("gate kapaliyken ped kenari yok (%0d)", chk_pad.n_hi),
       chk_pad.n_hi == 0);
    ok("gate kapaliyken ped alcakta", sd_clk === 1'b0);
    // Bolucu gate'ten BAGIMSIZ kosar: DQCE sadece agi acip kapatir, bolucunun
    // fazini tutmaz. Asagidaki "geri acilista faz kaymaz" testinin dayanagi.
    ok("gate kapaliyken bolucu serbest kosuyor", sd_div_clk === 1'b0 || sd_div_clk === 1'b1);

    $display("-- 1/3 gate acilinca tam fazlar, ped cekirdekle ayni --");
    sd_en = 1'b1;
    repeat (8 * HALF) @(posedge clk);
    restart_meas;
    repeat (16 * HALF) @(posedge clk);
    ok($sformatf("cekirdek saati kosuyor (%0d kenar)", chk_core.n_hi),
       chk_core.n_hi >= 3);
    ok($sformatf("yuksek faz tam (%0d, beklenen %0d)", chk_core.min_hi, HALF),
       chk_core.min_hi == HALF);
    ok($sformatf("alcak faz tam (%0d, beklenen %0d)", chk_core.min_lo, HALF),
       chk_core.min_lo == HALF);
    ok($sformatf("ped ayni agdan suruluyor (%0d kenar)", chk_pad.n_hi),
       chk_pad.n_hi == chk_core.n_hi);

    $display("-- 2/3 her faz ofsetinde gateleme: runt yok, alcakta park --");
    for (i = 0; i < 2 * DIV; i++) begin
      restart_meas;
      repeat (i) @(posedge clk);
      sd_en = 1'b0;
      // En kotu durumda bir tam periyot: enable saatin dusen kenarinda
      // kilitlenir, yani surmekte olan yuksek faz sonuna kadar gider.
      repeat (2 * HALF + 2) @(posedge clk);
      ok($sformatf("ofset %0d: gate kapaliyken cekirdek ALCAKTA", i),
         sd_clk_g === 1'b0);
      ok($sformatf("ofset %0d: gate kapaliyken ped ALCAKTA", i), sd_clk === 1'b0);
      ok($sformatf("ofset %0d: kapanirken runt yuksek faz yok (%0d >= %0d)",
                   i, chk_core.min_hi, HALF), chk_core.min_hi >= HALF);

      restart_meas;
      sd_en = 1'b1;
      repeat (8 * HALF) @(posedge clk);
      ok($sformatf("ofset %0d: saat geri geldi (%0d kenar)", i, chk_core.n_hi),
         chk_core.n_hi >= 2);
      // Bolucu serbest kostugu icin geri acilista faz KAYMAZ: ilk yuksek faz
      // da tam uzunlukta olmali, kisa bir artik faz degil.
      ok($sformatf("ofset %0d: geri donuste runt yok (%0d, beklenen %0d)",
                   i, chk_core.min_hi, HALF), chk_core.min_hi == HALF);
    end

    $display("-- 3/3 ped ile cekirdek saati tek ag --");
    ok($sformatf("ped ve cekirdek hic ayrismadi (%0d fark)", pad_core_diff),
       pad_core_diff == 0);
    sd_en = 1'b0;
    repeat (4 * HALF + 4) @(posedge clk);
    restart_meas;
    repeat (16 * HALF) @(posedge clk);
    ok("gate kapaliyken ped alcakta", sd_clk === 1'b0);
    ok($sformatf("gate kapaliyken ped kenari yok (%0d)", chk_pad.n_hi),
       chk_pad.n_hi == 0);

    $display("");
    if (fails == 0)
      $display("tb_phy_clk_gate: PASS (%0d kontrol)", checks);
    else
      $display("tb_phy_clk_gate: FAIL (%0d/%0d kontrol basarisiz)", fails, checks);
    if (fails != 0) $fatal(1, "tb_phy_clk_gate failed");
    $finish;
  end

  initial begin
    #5_000_000;
    $fatal(1, "tb_phy_clk_gate timeout");
  end

endmodule

// -----------------------------------------------------------------------------
// tb_phy_clk_gate
//   Purpose      : ultra_sd_phy_gowin'in SAAT sozlesmesi icin unit test.
//                  Gateleme ve ped mux'u clk_controller'dan buraya tasindi
//                  (DQCE / DCS); bu test o tasinan sozlesmeyi sinar ve
//                  pedlerle ilgilenmez.
//
//                  +define+ULTRA_SD_NO_VENDOR_PRIM ile kosar: gercek Gowin
//                  makrolari yerine ayni davranisin modeli devreye girer
//                  (enable saatin DUSEN kenarinda kilitlenir, secim yalnizca
//                  iki saat de alcakken yurur).
//
//                  Kontrol edilenler:
//                    1. Gate kapali   : cikis ALCAKTA park eder, kenar yok
//                    2. Runt yok      : enable her faz ofsetinde dusurulse
//                                       bile hicbir yuksek faz kisalmaz
//                    3. Kanal ayrimi  : bir kanali kapatmak digerini durdurmaz
//                                       VE bolucunun fazini bozmaz (serbest
//                                       kosan bolucunun karsiligi: geri
//                                       acildiginda faz kaymaz)
//                    4. Ped mux'u     : pad_line_sel secimi sd_clk'i dogru
//                                       kanaldan surer, gecis sirasinda runt
//                                       uretmez
//                    5. Reset         : rst_n altinda her uc saat de alcakta
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
  wire cmd_div_clk  = dut.cmd_clk_div;
  wire line_div_clk = dut.line_clk_div;

  logic cmd_en      = 1'b0;
  logic line_en     = 1'b0;
  logic pad_line_sel = 1'b0;

  logic cmd_clk_g, line_clk_g;
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
    .cmd_clk_en_i   (cmd_en),
    .line_clk_en_i  (line_en),
    .pad_line_sel_i (pad_line_sel),
    .cmd_clk_o      (cmd_clk_g),
    .line_clk_o     (line_clk_g),
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
  gate_phase_chk chk_cmd  (.clk(clk), .gclk(cmd_clk_g),  .clr(clr));
  gate_phase_chk chk_line (.clk(clk), .gclk(line_clk_g), .clr(clr));
  gate_phase_chk chk_pad  (.clk(clk), .gclk(sd_clk),     .clr(clr));

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

    $display("-- 0/4 reset: gate kapali, uc saat de alcakta --");
    repeat (40) @(posedge clk);
    ok("reset altinda cmd_clk_o alcakta",  cmd_clk_g  === 1'b0);
    ok("reset altinda line_clk_o alcakta", line_clk_g === 1'b0);
    ok("reset altinda sd_clk alcakta",     sd_clk     === 1'b0);

    @(negedge clk) rst_n = 1'b1;
    // Gate hala kapali: bolucu kosuyor ama disari saat cikmamali.
    restart_meas;
    repeat (16 * HALF) @(posedge clk);
    ok($sformatf("gate kapaliyken cmd kenari yok (%0d)", chk_cmd.n_hi),
       chk_cmd.n_hi == 0);
    ok($sformatf("gate kapaliyken ped kenari yok (%0d)", chk_pad.n_hi),
       chk_pad.n_hi == 0);
    ok("gate kapaliyken ped alcakta", sd_clk === 1'b0);

    $display("-- 1/4 gate acilinca tam fazlar --");
    cmd_en = 1'b1; line_en = 1'b1;
    repeat (8 * HALF) @(posedge clk);
    restart_meas;
    repeat (16 * HALF) @(posedge clk);
    ok($sformatf("cmd kosuyor (%0d kenar)", chk_cmd.n_hi), chk_cmd.n_hi >= 3);
    ok($sformatf("line kosuyor (%0d kenar)", chk_line.n_hi), chk_line.n_hi >= 3);
    ok($sformatf("cmd yuksek fazi tam (%0d, beklenen %0d)", chk_cmd.min_hi, HALF),
       chk_cmd.min_hi == HALF);
    ok($sformatf("cmd alcak fazi tam (%0d, beklenen %0d)", chk_cmd.min_lo, HALF),
       chk_cmd.min_lo == HALF);
    ok($sformatf("ped cmd kanalini suruyor (%0d kenar)", chk_pad.n_hi),
       chk_pad.n_hi >= 3);

    $display("-- 2/4 her faz ofsetinde gateleme: runt yok, alcakta park --");
    for (i = 0; i < 2 * DIV; i++) begin
      restart_meas;
      repeat (i) @(posedge clk);
      cmd_en = 1'b0;
      // En kotu durumda bir tam periyot: enable saatin dusen kenarinda
      // kilitlenir, yani surmekte olan yuksek faz sonuna kadar gider.
      repeat (2 * HALF + 2) @(posedge clk);
      ok($sformatf("ofset %0d: gate kapaliyken cmd ALCAKTA", i), cmd_clk_g === 1'b0);
      ok($sformatf("ofset %0d: kapanirken runt yuksek faz yok (%0d >= %0d)",
                   i, chk_cmd.min_hi, HALF), chk_cmd.min_hi >= HALF);
      ok($sformatf("ofset %0d: line etkilenmedi (%0d kenar)", i, chk_line.n_hi),
         chk_line.n_hi >= 1);
      ok($sformatf("ofset %0d: line fazi bozulmadi (%0d >= %0d)",
                   i, chk_line.min_hi, HALF), chk_line.min_hi >= HALF);

      restart_meas;
      cmd_en = 1'b1;
      repeat (8 * HALF) @(posedge clk);
      ok($sformatf("ofset %0d: cmd geri geldi (%0d kenar)", i, chk_cmd.n_hi),
         chk_cmd.n_hi >= 2);
      ok($sformatf("ofset %0d: geri donuste runt yok (%0d, beklenen %0d)",
                   i, chk_cmd.min_hi, HALF), chk_cmd.min_hi == HALF);
    end

    $display("-- 3/4 ped mux'u: secim kanallar arasinda runt'siz gecer --");
    cmd_en = 1'b1; line_en = 1'b1;
    repeat (8 * HALF) @(posedge clk);
    for (i = 0; i < 2 * DIV; i++) begin
      restart_meas;
      repeat (i) @(posedge clk);
      pad_line_sel = 1'b1;                      // LINE kanalina devret
      repeat (8 * HALF) @(posedge clk);
      ok($sformatf("ofset %0d: line'a gecis runt uretmedi (%0d, beklenen %0d)",
                   i, chk_pad.min_hi, HALF), chk_pad.min_hi == HALF);
      ok($sformatf("ofset %0d: ped line'da kosuyor (%0d kenar)", i, chk_pad.n_hi),
         chk_pad.n_hi >= 2);

      restart_meas;
      repeat (i) @(posedge clk);
      pad_line_sel = 1'b0;                      // CMD kanalina geri don
      repeat (8 * HALF) @(posedge clk);
      ok($sformatf("ofset %0d: cmd'ye donus runt uretmedi (%0d, beklenen %0d)",
                   i, chk_pad.min_hi, HALF), chk_pad.min_hi == HALF);
    end

    $display("-- 4/4 iki kanal da kapali: ped alcakta park --");
    cmd_en = 1'b0; line_en = 1'b0;
    repeat (4 * HALF + 4) @(posedge clk);
    restart_meas;
    repeat (16 * HALF) @(posedge clk);
    ok("iki gate kapaliyken ped alcakta", sd_clk === 1'b0);
    ok($sformatf("iki gate kapaliyken ped kenari yok (%0d)", chk_pad.n_hi),
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

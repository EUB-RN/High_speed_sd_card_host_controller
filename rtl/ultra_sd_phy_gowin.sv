

module ultra_sd_phy_gowin
  import ultra_sd_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   soft_clr,   // SENKRON yazilim clear'i;
                                             // asenkron reset pinine girmez

  /* verilator lint_off UNUSED */
  input  logic [CFG_PHY_W-1:0]   cfg_phy_i,
  /* verilator lint_on UNUSED */

  // Bolme orani; ham saatler artik bu modulun ICINDE uretilir.
  input  logic [CFG_CLK_W-1:0]   clk_div_i,

  input  logic                   sd_clk_en_i,

  // Cekirdegin kostugu TEK gate'lenmis SD saati (L1, L2, L3 ve rampa sayaci).
  output logic                   sd_clk_o,

  input  logic                   cmd_out_i,
  input  logic                   cmd_oe_i,
  output logic                   cmd_in_o,

  input  logic [SD_DATA_LANES-1:0] dat_out_i,
  input  logic [SD_DATA_LANES-1:0] dat_oe_i,
  output logic [SD_DATA_LANES-1:0] dat_in_o,

  output logic                   sd_clk,
  inout  wire                    sd_cmd,
  inout  wire  [3:0]             sd_dat
);

  // ---------------------------------------------------------------------------
  // Ham (gate'lenmemis, serbest kosan) SD saati. Bolucu sahibin yaninda duruyor:
  // saat uretimi ve gate'leme tek modulde, boylece bolunmus saat fabric'te
  // modul siniri gecmiyor.
  //
  // TEK saat, tek gate. Burada eskiden iki kanal (CMD / LINE), iki DQCE ve
  // aralarinda secim yapan bir DCS vardi. Ucu de olu mantikti: kartin tek saat
  // pedi oldugu icin iki kanal ayni bolucuden, ayni oranla besleniyordu,
  // pad_line_sel sabit 0 baglanmisti ve line_clk_en cmd_clk_en'in kopyasiydi.
  // Bedeli kagit uzerinde degildi: ayni dalga formu IKI global saat agi
  // tuketiyor, STA iki ayri base clock goruyor ve L1 <-> L3 arasindaki her yol
  // gereksiz yere saatler-arasi yol olarak analiz ediliyordu. Tek ag, tek
  // clock, ayni davranis.
  // ---------------------------------------------------------------------------
  logic sd_clk_div;

  clk_controller u_clk_controller (
    .clk_i (clk),
    .rst_n (rst_n),
    .div_i (clk_div_i),
    .clk_o (sd_clk_div)
  );

  logic [CFG_PHY_PHASE_W-1:0] phase_q;
  logic                       sd_clk_q;
  logic [CFG_PHY_PHASE_W-1:0] phase_cnt_q;
  logic                       samp_pend_q;

  logic sd_clk_fab;
  assign sd_clk_fab = sd_clk_div & sd_clk_en_i;

  logic sd_rise;
  assign sd_rise = sd_clk_fab & ~sd_clk_q;

  logic samp_en;
  assign samp_en = sd_rise ? ((phase_q == '0) | samp_pend_q)
                           : (samp_pend_q & (phase_cnt_q == '0));

  logic                     cmd_in_q;
  logic [SD_DATA_LANES-1:0] dat_in_q;
  logic                     pad_en_q;

  logic                     cmd_pad_in;
  logic [SD_DATA_LANES-1:0] dat_pad_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin

      pad_en_q    <= 1'b0;
      cmd_in_q    <= 1'b1;
      dat_in_q    <= {SD_DATA_LANES{1'b1}};
      phase_q     <= '0;
      sd_clk_q    <= 1'b0;
      phase_cnt_q <= '0;
      samp_pend_q <= 1'b0;
    end else begin
      pad_en_q <= 1'b1;

      phase_q  <= cfg_phy_i[CFG_PHY_PHASE_LSB +: CFG_PHY_PHASE_W];

      sd_clk_q <= sd_clk_fab;

      if (sd_rise) begin

        samp_pend_q <= (phase_q != '0);
        phase_cnt_q <= (phase_q == '0) ? '0
                                       : (phase_q - CFG_PHY_PHASE_W'(1));
      end else if (samp_pend_q) begin
        if (phase_cnt_q != '0) begin
          phase_cnt_q <= phase_cnt_q - CFG_PHY_PHASE_W'(1);
        end else begin
          samp_pend_q <= 1'b0;
        end
      end

      if (samp_en) begin
        cmd_in_q <= cmd_pad_in;
        dat_in_q <= dat_pad_in;
      end

      if (soft_clr) begin
        // pad_en_q BILEREK yok: amaci "pedler henuz acilmadi" demek ve reset
        // sonrasi bir daha asla degismemek. constr/ultra_sd.sdc ona tam bu
        // gerekceyle set_false_path -from pad_en_q/Q koyuyor; soft reset onu
        // oynatirsa o kisit yalan olur ve ped cikis enable'i analiz disi kalir.
        // Soft reset pedleri yeniden tri-state'e almak zorunda da degil.
        cmd_in_q    <= 1'b1;
        dat_in_q    <= {SD_DATA_LANES{1'b1}};
        phase_q     <= '0;
        sd_clk_q    <= 1'b0;
        phase_cnt_q <= '0;
        samp_pend_q <= 1'b0;

        // Preserve registers not reset by software clear.
        pad_en_q <= pad_en_q;
      end
    end
  end

  assign cmd_in_o = cmd_in_q;
  assign dat_in_o = dat_in_q;

  logic                     cmd_oe;
  logic [SD_DATA_LANES-1:0] dat_oe;

  assign cmd_oe = pad_en_q & cmd_oe_i;
  assign dat_oe = {SD_DATA_LANES{pad_en_q}} & dat_oe_i;

  logic sd_clk_g;

`ifdef ULTRA_SD_NO_VENDOR_PRIM

  // DQCE'nin davranissal modeli: enable bolunmus saatin DUSEN kenarinda
  // orneklenir, yani ag yalnizca saat alcaktayken acilip kapanir -- runt yok.
  logic ce_q;

  always_ff @(negedge sd_clk_div or negedge rst_n) begin
    if (!rst_n) ce_q <= 1'b0;
    else        ce_q <= sd_clk_en_i;
  end

  assign sd_clk_g = sd_clk_div & ce_q;
`else
  DQCE u_dqce_sd (
    .CLKOUT (sd_clk_g),
    .CLKIN  (sd_clk_div),
    .CE     (sd_clk_en_i)
  );
`endif

  // Ped de cekirdek de ayni gate'lenmis agdan surulur: arada secim yok, yani
  // secimi yapacak bir DCS de yok. Kartin gordugu saat ile cekirdegin kostugu
  // saat TANIM GEREGI ayni dalga formu.
  assign sd_clk_o = sd_clk_g;
  assign sd_clk   = sd_clk_g;

`ifdef ULTRA_SD_NO_VENDOR_PRIM
  assign sd_cmd     = cmd_oe ? cmd_out_i : 1'bz;
  assign cmd_pad_in = sd_cmd;

  for (genvar ln = 0; ln < SD_DATA_LANES; ln++) begin : g_dat_pad
    assign sd_dat[ln]     = dat_oe[ln] ? dat_out_i[ln] : 1'bz;
    assign dat_pad_in[ln] = sd_dat[ln];
  end
`else
  IOBUF u_iobuf_cmd (
    .O   (cmd_pad_in),
    .IO  (sd_cmd),
    .I   (cmd_out_i),
    .OEN (~cmd_oe)
  );

  for (genvar ln = 0; ln < SD_DATA_LANES; ln++) begin : g_dat_pad
    IOBUF u_iobuf_dat (
      .O   (dat_pad_in[ln]),
      .IO  (sd_dat[ln]),
      .I   (dat_out_i[ln]),
      .OEN (~dat_oe[ln])
    );
  end
`endif

endmodule

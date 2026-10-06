// -----------------------------------------------------------------------------
// system_controller
//   Purpose      : Reset, kart-varligi ve SISTEM FAZI merkezi. Tasarimdaki TEK
//                  reset senkronizasyonu burada yapilir: dis pindeki rst_n
//                  asenkron kurulur, senkron birakilir (R-CLK-1), ve
//                  CTRL.SOFT_RESET ile OR'lanarak cekirdege dagitilir.
//
//                  FAZ 0 sozlesmesi. core_rst_n cekilirken her blok kendi
//                  reset degerine oturur; birakilma kenari butun bloklara
//                  AYNI clk kenarinda gorunur, cunku dagitilan tek bir
//                  senkron reset hattidir. Blok basina ayri senkronizer
//                  yoktur -- olsaydi bloklar birbirinden bir cevrim kaymis
//                  sekilde kalkabilirdi.
//
//                  sd_cd pedi ACTIVE LOW'dur (0 = kart var) ve asenkron,
//                  mekanik olarak ziplayan bir girdidir: once iki-flop
//                  senkronizer, sonra sayac tabanli debounce'dan gecer.
//
//                  Ustte, sistemin kabaca hangi asamada oldugunu takip eden
//                  bir faz FSM'i durur (sys_phase_e):
//                    FAZ 1  SYS_RESET        reset etkin / yeni birakildi
//                    FAZ 2  SYS_CARD_DETECT  kart takili mi, debounce'li
//                    FAZ 3  SYS_RAMP         ilk komuttan once >=74 SD kenari
//                    FAZ 4  SYS_CONFIG       init merdiveni / konfigurasyon
//                    FAZ 5  SYS_READ          veri okuma transferi
//                    FAZ 6  SYS_WRITE         veri yazma transferi
//                  FSM rst_n_o alanindadir, core_rst_n_o alaninda DEGIL: soft
//                  reset cekirdegi sifirlarken FSM ayakta kalip fazi FAZ 1'e
//                  dondurur, yani yeniden baslatmayi gozleyen taraf odur.
//
//                  SYS_CONFIG transferler arasindaki EV fazidir: init
//                  merdiveni orada kosar, bitince FSM orada bosta bekler ve
//                  veri fazlari oraya doner. Ayri bir SYS_IDLE yok, cunku
//                  "init bitti mi" sorusunun cevabi zaten init_done_i /
//                  STATUS.CARD_READY -- fazi ikiye bolmek ayni bilgiyi iki
//                  yerde tutmak olurdu.
//
//                  Veri fazlari transferin KENDISINI yurutmez: o is L3
//                  (ultra_sd_block) ve L2'nin. Buradaki FSM yalnizca
//                  sistemin hangi yonde mesgul oldugunu tasir ve saati acik
//                  tutar; transferi baslatan start_i darbesi ile bitiren
//                  xfer_done_i / xfer_err_i / abort_i ayni darbelerdir, yani
//                  faz ile L3'un FSM'i kaymaz. Hat start'lari (dat_tx_start /
//                  dat_rx_start) L3'un isidir, burada uretilmez.
//
//                  PEDE GIDEN SAAT. clk_controller iki saat uretir: cmd_clk
//                  (L2'yi saatler) ve line_clk (L1'i saatler). Fiziksel
//                  sd_clk pedi TEKTIR, dolayisiyla pede AKTIF OLAN saat
//                  baglanir: veri fazlarinda line_clk, diger her yerde
//                  cmd_clk. Secim kombinasyonel DEGIL, kayitlidir ve
//                  yalnizca her iki saat de ALCAKTA iken degisir -- boylece
//                  mux ne glitch ne de runt pulse uretebilir. Iki kanal ayni
//                  bolme oranindan surulur, yani devir teslim aninda pedin
//                  gordugu frekans da degismez.
//
//                  KULLANILAN HATLAR. ultra_sd_line'in lane_en_i maskesini
//                  bu modul surer: LSB'den bitisik maske, 4'b0001 = yalniz
//                  DAT0, 4'b1111 = DAT3..DAT0. Maske veri fazina GIRISTE
//                  kilitlenir ve transfer boyunca sabit kalir (L1 genisligi
//                  transfer ortasinda degistiremez). Veri fazlari disinda
//                  maske 4'b0001'dir: init merdiveni her zaman 1 bit kosar.
//
//                  SAAT YONETIMI de burada: clk_controller bu modulun icinde
//                  ornekleniyor ve bolme orani ile gateleme dogrudan faz
//                  FSM'inden suruluyor. Sozlesme:
//                    FAZ 1/2  saat KAPALI, alcakta park (kart yoksa SD saati
//                             surmenin anlami yok, R-PWR gerekcesi)
//                    FAZ 3    saat ACIK, en yavas bolme ('1, <=400 kHz)
//                    FAZ 4    saat ACIK, oran clk_div_i'den gelir (init
//                             merdiveni DS/HS'e gecerken burayi yukseltir)
//                  Bolme orani yalnizca saat KAPALIYKEN ya da periyot
//                  sinirinda degisir; clk_controller zaten orani periyot
//                  basinda orneklediginden runt pulse olusmaz.
//
//   Clock domain : clk (sistem saati). sd_cd clk alanina burada girer.
//                  cmd_clk_o / line_clk_o uretilmis saatlerdir. sd_rise_o,
//                  cmd_clk_o'nun yukselen kenarini clk alaninda gosteren
//                  tek-cevrimlik strobe'dur -- rampa sayimi SD kenarlarini
//                  saymak zorundadir, clk degil. Uretilmis saat clk'den tek
//                  bir flop ile cikti icin bu kenar algilama senkrondur,
//                  CDC degildir.
//   Reset scheme : rst_n_i asenkron assert / senkron deassert (R-CLK-1)
//   Implements   : Spec Section 3.2 (reset), R-CLK-1, R-CLK-3 (iki-flop
//                  senkronizer, tek-bit kontrol), R-IF-10 (CARD_CHANGE IRQ),
//                  R-FUNC-2 (74-clock rampa penceresi)
// -----------------------------------------------------------------------------
// Not: paket importu modul govdesinde; parametre listesinden ONCE yapilan
// header importunu iverilog kabul etmiyor.
module system_controller #(
  // Debounce penceresi, clk cevrimi cinsinden. 100 MHz'de ~1 ms.
  parameter int CD_DEBOUNCE_CYC = 100_000,
  // Reset birakma senkronizer derinligi (R-CLK-3 asgari iki flop).
  parameter int RST_SYNC_STAGES = 2,
  // R-FUNC-2: karta ilk komut gonderilmeden once en az 74 SD saat kenari.
  parameter int RAMP_CLOCKS     = 74,
  // Baslatma bolme orani. Repo sozlesmesi: '1 = en yavas = <=400 kHz; hem
  // REG_CFG_CLK hem ultra_sd_init reset degeri olarak bunu kullanir.
  parameter int INIT_CLK_DIV    = 255
) (
  input  logic clk,
  input  logic rst_n_i,          // dis pin, asenkron

  // ---- yazilim resetleri ---------------------------------------------------
  input  logic soft_reset_i,     // CTRL.SOFT_RESET, tek cevrimlik darbe

  // ---- kart algilama pedi --------------------------------------------------
  input  logic sd_cd_i,          // ACTIVE LOW: 0 = kart takili

  // ---- istenen bolme orani, FAZ 4'ten itibaren gecerli ---------------------
  // REG_CFG_CLK ya da ultra_sd_init.clk_div_o. FAZ 4'ten once yok sayilir:
  // rampa her zaman en yavas oranda kosar.
  input  logic [ultra_sd_pkg::CFG_CLK_W-1:0] clk_div_i,

  // ---- transfer istegi ve tamamlanmasi -------------------------------------
  // init_done_i = STATUS.CARD_READY: kart konfigure edilmeden transfer
  // baslamaz, START darbesi o halde yok sayilir (sahipligi reg dosyasina
  // birakmak yerine burada reddediyoruz ki faz asla yalan soylemesin).
  input  logic init_done_i,
  input  logic start_i,          // CTRL.START darbesi
  input  logic dir_i,            // XFER.DIR: 0 = okuma, 1 = yazma
  input  logic abort_i,          // CTRL.ABORT darbesi
  input  logic xfer_done_i,      // L3 done_o, transfer bitti
  input  logic xfer_err_i,       // L3 err_valid_o, transfer hatayla bitti

  // ---- hat genisligi -------------------------------------------------------
  // bus_4bit_i : STATUS.BUS_WIDTH / ultra_sd_init.bus_4bit_o (ACMD6 sonucu)
  // force_1bit_i : CFG_PHY[FORCE_1BIT], R-DEG-4 kademeli dusurme. Zorlama
  //                her zaman kazanir: yazilim 4 bit hattan vazgecebilmeli.
  input  logic bus_4bit_i,
  input  logic force_1bit_i,

  // ---- cekirdege dagitilan reset -------------------------------------------
  output logic rst_n_o,          // sadece dis reset, senkron birakilmis
  output logic core_rst_n_o,     // dis reset + soft reset

  // ---- kart durumu, clk alaninda -------------------------------------------
  output logic card_present_o,   // 1 = kart var (pedin tersi)
  output logic card_change_o,    // tek cevrimlik darbe, IRQ CARD_CHANGE

  // ---- uretilmis saatler, clk_controller ciktisi ---------------------------
  output logic cmd_clk_o,        // L2'yi (ultra_sd_cmd) saatler
  output logic line_clk_o,       // L1'i (ultra_sd_line) saatler
  output logic sd_clk_o,         // PEDE giden saat: aktif olan kanal
  output logic sd_rise_o,        // cmd_clk_o yukselen kenari, clk alaninda

  // ---- L1'e hat maskesi ----------------------------------------------------
  output logic [ultra_sd_pkg::SD_DATA_LANES-1:0] lane_en_o,

  // ---- sistem fazi ---------------------------------------------------------
  output ultra_sd_pkg::sys_phase_e sys_phase_o,  // FSM durumu, FAZ 1..4
  output logic       sd_clk_en_o,  // clk_controller gate: rampadan itibaren 1
  output logic       ramp_done_o,  // 74 kenar tamamlandi, seviye
  output logic       cfg_start_o   // FAZ 4'e giriste tek cevrimlik darbe
);

  import ultra_sd_pkg::*;

  // Soft reset'in cekirdegi kac cevrim tutacagi. Tek bir darbe, uzerinde
  // calisilan sd_clk yarim periyodundan kisa kalmasin diye genisletilir.
  localparam int SOFT_RST_CYC = 16;

  localparam int SOFT_CNT_W = $clog2(SOFT_RST_CYC + 1);
  localparam int CD_CNT_W   = $clog2(CD_DEBOUNCE_CYC + 1);
  localparam int RAMP_CNT_W = $clog2(RAMP_CLOCKS + 1);

  // ---------------------------------------------------------------------------
  // Reset birakma senkronizeri. Asenkron kurulur (negedge rst_n_i), senkron
  // birakilir: zincire 1 surulur ve clk ile ilerler.
  // ---------------------------------------------------------------------------
  logic [RST_SYNC_STAGES-1:0] rst_sync_q;

  always_ff @(posedge clk or negedge rst_n_i) begin
    if (!rst_n_i) begin
      rst_sync_q <= '0;
    end else begin
      rst_sync_q <= {rst_sync_q[RST_SYNC_STAGES-2:0], 1'b1};
    end
  end

  assign rst_n_o = rst_sync_q[RST_SYNC_STAGES-1];

  // ---------------------------------------------------------------------------
  // Soft reset genisletici. Buradan asagisi artik senkron reset alanindadir:
  // tum flop'lar rst_n_o ile asenkron kurulur.
  // ---------------------------------------------------------------------------
  logic [SOFT_CNT_W-1:0] soft_cnt_q;
  logic                  soft_rst_n_q;

  // ---------------------------------------------------------------------------
  // sd_cd: iki-flop senkronizer + debounce sayaci.
  // ---------------------------------------------------------------------------
  logic [1:0]          cd_sync_q;
  logic                cd_stable_q;   // debounce edilmis ped degeri (active low)
  logic [CD_CNT_W-1:0] cd_cnt_q;
  logic                card_present_q;
  logic                card_change_q;

  // ---------------------------------------------------------------------------
  // Faz FSM'i durumu.
  // ---------------------------------------------------------------------------
  sys_phase_e            phase_q;
  logic [RAMP_CNT_W-1:0] ramp_cnt_q;
  logic                  cfg_start_q;

  // Senkronizer cikisinin ham, debounce edilmemis hali. Debounce karsilastirmasi
  // bunun uzerinden yapilir.
  logic cd_raw;
  assign cd_raw = cd_sync_q[1];

  // ---------------------------------------------------------------------------
  // Saat kontrolu. Hem oran hem gateleme fazin saf bir fonksiyonudur: FSM
  // durumu disinda hicbir sey saati acip kapatamaz, boylece "saat ne zaman
  // kosuyordu" sorusunun tek bir cevabi olur.
  //
  // FAZ 1/2'de gate kapali: clk_controller cikisi alcakta park eder.
  // FAZ 3'te rampa her zaman en yavas oranda kosar (R-FUNC-2: ilk 74 kenar
  // <=400 kHz olmak zorunda, yazilim CFG_CLK'e ne yazmis olursa olsun).
  // FAZ 4..6'da oran clk_div_i'den gelir; veri fazlarinin rampadan farki yok,
  // transfer sirasinda saati durdurmak ya da orani degistirmek bu modulun
  // isi degildir (R-DEG-1 orani CFG_CLK uzerinden yazilima birakir).
  // ---------------------------------------------------------------------------
  logic                  sd_clk_en;
  logic [CFG_CLK_W-1:0]  sd_clk_div;
  logic                  line_phase;    // veri fazinda miyiz

  assign line_phase = (phase_q == SYS_READ) || (phase_q == SYS_WRITE);

  // Saat, rampadan itibaren her fazda kosar: bir kere baslayan SD saati
  // transferler arasinda da durmaz.
  assign sd_clk_en  = (phase_q != SYS_RESET) && (phase_q != SYS_CARD_DETECT);
  assign sd_clk_div = (phase_q == SYS_RAMP) ? CFG_CLK_W'(INIT_CLK_DIV)
                                            : clk_div_i;

  // Iki kanal AYNI gate'ten ve AYNI orandan surulur, ve bu bir zorunluluk:
  //
  //   Kartin tek bir saat pini var. CMD ve DAT uzerinde surulen/orneklenen
  //   her bit o pindeki kenara gore tanimlidir. Iki kanal faz olarak ayrilsa,
  //   pede hangi kanal bagli olursa olsun diger katman kendi kenarina gore
  //   surmeye devam eder ve kartin gordugu kenar ile host'un surdugu kenar
  //   kayar.
  //
  //   clk_controller'da kanallari BAGIMSIZ gatelemek tam bunu yapar: kapali
  //   bir kanalda clk_q hic yukselmedigi icin period_start her YARIM periyotta
  //   bir dogar, yani kanal yeniden acildiginda calisan kanala gore yarim
  //   periyot kaymis baslayabilir. Bu yuzden gate tek, oran tek.
  //
  // Veri fazlarinda line_clk'in bos bos toggle etmesi bunun bedeli; karsiligi
  // DAT motorunun ornekleme kenarinin pedin kenariyla bire bir ayni olmasi.
  logic cmd_clk_en;
  logic line_clk_en;

  assign cmd_clk_en  = sd_clk_en;
  assign line_clk_en = sd_clk_en;

  clk_controller u_clk_controller (
    .clk_i      (clk),
    // core_rst_n_o DEGIL: soft reset saat uretecini periyot ortasinda
    // kesmemeli. Soft reset zaten fazi FAZ 1'e dondurur, orada gate kapanir
    // ve saat periyot sinirinda duzgunce alcakta park eder.
    .rst_n      (rst_n_o),
    .cmd_div_i  (sd_clk_div),
    .line_div_i (sd_clk_div),
    .cmd_en_i   (cmd_clk_en),
    .line_en_i  (line_clk_en),
    .cmd_clk_o  (cmd_clk_o),
    .line_clk_o (line_clk_o)
  );

  // ---------------------------------------------------------------------------
  // PEDE giden saat secimi. Kayitli secim, yalnizca HER IKI saat de alcakta
  // iken degisir: boylece ne surmekte olan bir yuksek faz kesilir (runt
  // pulse) ne de iki kaynak arasinda kombinasyonel bir glitch olusur. Boyle
  // bir pencerenin varligi garanti: kapali kanal alcakta park eder, kosan
  // kanal da her periyotta bir alcak yariya iner.
  //
  // Iki kanal ayni gate ve ayni orandan surulur, dolayisiyla dalga bicimleri
  // bit bir ayni; secim pedin kenarini AKTIF motorun kullandigi kenarla ayni
  // tutar ve oranlar ileride ayrilirsa dogru kanali secmeye devam eder.
  // Kanallar ayni oldugu surece devir teslim tanim geregi kesintisizdir.
  // ---------------------------------------------------------------------------
  logic pad_line_q;   // 1 = ped line_clk'ten surulur

  always_ff @(posedge clk or negedge rst_n_o) begin
    if (!rst_n_o) begin
      pad_line_q <= 1'b0;                 // ped cmd_clk'ten baslar
    end else if (!cmd_clk_o && !line_clk_o) begin
      pad_line_q <= line_phase;
    end
  end

  assign sd_clk_o = pad_line_q ? line_clk_o : cmd_clk_o;

  // ---------------------------------------------------------------------------
  // Kullanilacak DAT hatlari. Genislik veri fazina GIRISTE kilitlenir: L1
  // genisligi transfer ortasinda degistiremez, o yuzden kaynak da
  // degistirmemeli. Veri fazlari disinda maske 4'b0001'dir -- init merdiveni
  // ACMD6'ya kadar 1 bit kosar ve kullanilmayan hatlar yuksek empedansta
  // kalir (L1 oe'yi hat basina maskeler).
  // ---------------------------------------------------------------------------
  logic [SD_DATA_LANES-1:0] lane_en_q;

  // Istenen maske: zorlama her zaman kazanir (R-DEG-4).
  logic [SD_DATA_LANES-1:0] lane_en_req;
  assign lane_en_req = (bus_4bit_i && !force_1bit_i) ? 4'b1111 : 4'b0001;

  always_ff @(posedge clk or negedge rst_n_o) begin
    if (!rst_n_o) begin
      lane_en_q <= 4'b0001;               // 1 bit, init ile ayni
    end else if (!line_phase) begin
      // Veri fazi disinda maske serbestce takip eder: transfer basladiginda
      // kilitlenecek deger budur.
      lane_en_q <= lane_en_req;
    end
  end

  assign lane_en_o = lane_en_q;

  // ---------------------------------------------------------------------------
  // Uretilmis saatin yukselen kenari. cmd_clk_o clk'den tek bir flop ile
  // ciktigi icin bir cevrim gecikmeli kayit ile kenari tam olarak yakalariz;
  // senkronizer gerekmez (ayni saat alani).
  // ---------------------------------------------------------------------------
  logic cmd_clk_d_q;
  logic sd_rise;

  always_ff @(posedge clk or negedge rst_n_o) begin
    if (!rst_n_o) cmd_clk_d_q <= 1'b0;
    else          cmd_clk_d_q <= cmd_clk_o;
  end

  assign sd_rise = cmd_clk_o & ~cmd_clk_d_q;

  // Rampanin son kenari: bu cevrimde sayac tukeniyor.
  logic ramp_last;
  assign ramp_last = sd_rise & (ramp_cnt_q == RAMP_CNT_W'(1));

  always_ff @(posedge clk or negedge rst_n_o) begin
    if (!rst_n_o) begin
      // ---- FAZ 0 reset degerleri --------------------------------------------
      soft_cnt_q     <= '0;
      soft_rst_n_q   <= 1'b1;   // soft reset bos: cekirdegi tutan sadece rst_n
      // Ped yukari cekilidir (kart yok). Senkronizer de o degerle baslar ki
      // reset birakildiginda sahte bir CARD_CHANGE darbesi uretilmesin.
      cd_sync_q      <= 2'b11;
      cd_stable_q    <= 1'b1;
      cd_cnt_q       <= '0;
      card_present_q <= 1'b0;   // STATUS.CARD_PRESENT = 0
      card_change_q  <= 1'b0;
      // ---- faz FSM reset degerleri ------------------------------------------
      phase_q        <= SYS_RESET;
      ramp_cnt_q     <= RAMP_CNT_W'(RAMP_CLOCKS);
      cfg_start_q    <= 1'b0;
    end else begin
      // ---- soft reset genisletme --------------------------------------------
      // Darbe gelirse sayac yuklenir; sayac bosalana kadar soft_rst_n_q
      // cekili kalir. Darbe sayac koserken yeniden gelirse pencere tazelenir.
      if (soft_reset_i) begin
        soft_rst_n_q <= 1'b0;
        soft_cnt_q   <= SOFT_CNT_W'(SOFT_RST_CYC);
      end else if (soft_cnt_q != '0) begin
        soft_cnt_q   <= soft_cnt_q - SOFT_CNT_W'(1);
      end else begin
        soft_rst_n_q <= 1'b1;
      end

      // ---- sd_cd senkronizeri -----------------------------------------------
      cd_sync_q <= {cd_sync_q[0], sd_cd_i};

      // ---- debounce ---------------------------------------------------------
      // Ham deger kararli degerden farkli oldugu SURECE sayilir; bir kere
      // geri ziplasa sayac sifirlanir, yani pencere bastan baslar.
      card_change_q <= 1'b0;
      if (cd_raw == cd_stable_q) begin
        cd_cnt_q <= '0;
      end else if (cd_cnt_q == CD_CNT_W'(CD_DEBOUNCE_CYC)) begin
        cd_cnt_q       <= '0;
        cd_stable_q    <= cd_raw;
        card_present_q <= ~cd_raw;  // ped active low
        card_change_q  <= 1'b1;     // R-IF-10, tek cevrimlik
      end else begin
        cd_cnt_q <= cd_cnt_q + CD_CNT_W'(1);
      end

      // ---- faz FSM ----------------------------------------------------------
      cfg_start_q <= 1'b0;

      unique case (phase_q)
        // FAZ 1: reset. Dis reset burada zaten birakilmis olur (bu blok
        // rst_n_o ile kurulur), o yuzden beklenen tek sey soft reset
        // penceresinin kapanmasi.
        SYS_RESET: begin
          ramp_cnt_q <= RAMP_CNT_W'(RAMP_CLOCKS);
          if (soft_rst_n_q && !soft_reset_i) begin
            phase_q <= SYS_CARD_DETECT;
          end
        end

        // FAZ 2: kart algilama. Debounce edilmis varlik sinyali beklenir.
        SYS_CARD_DETECT: begin
          ramp_cnt_q <= RAMP_CNT_W'(RAMP_CLOCKS);
          if (card_present_q) begin
            phase_q <= SYS_RAMP;
          end
        end

        // FAZ 3: 74-clock rampa (R-FUNC-2). SD kenari sayilir, clk degil.
        SYS_RAMP: begin
          if (sd_rise && (ramp_cnt_q != '0)) begin
            ramp_cnt_q <= ramp_cnt_q - RAMP_CNT_W'(1);
          end
          if (ramp_last) begin
            phase_q     <= SYS_CONFIG;
            cfg_start_q <= 1'b1;
          end
        end

        // FAZ 4: konfigurasyon, ayni zamanda transferler arasindaki ev fazi.
        // Init bitmeden gelen START darbesi sessizce yok sayilir: hata
        // bildirmek reg dosyasinin / L3'un isi (ERR_CARD_STATE), fazin isi
        // sistemin nerede oldugunu dogru soylemek.
        SYS_CONFIG: begin
          if (start_i && init_done_i) begin
            phase_q <= dir_i ? SYS_WRITE : SYS_READ;
          end
        end

        // FAZ 5 / FAZ 6: veri transferi. Her ikisi de ayni sekilde biter --
        // basari, hata ya da abort. Ucu de tek cevrimlik darbedir, yani
        // transfer bittiginde faz da ayni kenarda eve doner.
        SYS_READ, SYS_WRITE: begin
          if (xfer_done_i || xfer_err_i || abort_i) begin
            phase_q <= SYS_CONFIG;
          end
        end

        default: phase_q <= SYS_RESET;
      endcase

      // Faz FSM'ini her durumdan geri cagiran iki olay. Case'ten SONRA
      // yazildiklari icin yukaridaki atamalari ezerler -- oncelik sirasi:
      // soft reset > kart cikarma > normal ilerleme.
      if (!card_present_q && (phase_q != SYS_RESET)) begin
        phase_q     <= SYS_CARD_DETECT;
        ramp_cnt_q  <= RAMP_CNT_W'(RAMP_CLOCKS);
        cfg_start_q <= 1'b0;
      end
      if (soft_reset_i) begin
        phase_q     <= SYS_RESET;
        ramp_cnt_q  <= RAMP_CNT_W'(RAMP_CLOCKS);
        cfg_start_q <= 1'b0;
      end
    end
  end

  assign core_rst_n_o   = rst_n_o & soft_rst_n_q;
  assign card_present_o = card_present_q;
  assign card_change_o  = card_change_q;

  assign sys_phase_o    = phase_q;
  // Saat rampa fazinda baslar: 74 kenarin sayilabilmesi icin saatin zaten
  // kosuyor olmasi gerekir. Kart yokken ya da resette alcakta park eder.
  // Disari da verilir: PHY'nin ve init'in "SD saati kosuyor mu" sorusuna
  // ayni cevabi vermesi gerekir.
  assign sd_clk_en_o    = sd_clk_en;
  assign sd_rise_o      = sd_rise;
  // Rampa bir kez bittiginde sonraki butun fazlarda bitmis sayilir; kart
  // cikarilip FAZ 2'ye donuldugunde yeniden duser.
  assign ramp_done_o    = (phase_q == SYS_CONFIG) ||
                          (phase_q == SYS_READ)   ||
                          (phase_q == SYS_WRITE);
  assign cfg_start_o    = cfg_start_q;

endmodule

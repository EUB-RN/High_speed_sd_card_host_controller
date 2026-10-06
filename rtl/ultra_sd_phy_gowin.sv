// -----------------------------------------------------------------------------
// ultra_sd_phy_gowin
//   Purpose      : L0. Satici (vendor) primitifi iceren TEK dosya: IOBUF ve
//                  diger Gowin makrolari yalnizca burada bulunabilir
//                  (R-ARCH-2). Uc-durum kontrolu, ornekleme fazi mux'u ve
//                  pedlerin reset altinda park etmesi burada yapilir.
//                  Protokol bilgisi YOK, komut opcode'u YOK, PLL YOK
//                  (R-CLK-5).
//
//                  SAAT URETIMI BURADA DEGIL. clk_controller
//                  system_controller icinde ornekleniyor, cunku hangi saatin
//                  hangi fazda kosacagina karar veren taraf faz FSM'idir.
//                  Bu modul pede gidecek saati hazir alir (sd_clk_i) ve
//                  yalnizca pede baglar -- yolda mantik yoktur, dolayisiyla
//                  fabric'te uretilmis/gatelenmis yeni bir saat de yoktur.
//
//   ---------------------------------------------------------------------------
//   CIKIS YOLU: KAYIT YOK, BILEREK
//   ---------------------------------------------------------------------------
//   cmd_out_i / dat_out_i zaten L2 ve L1'in NEGEDGE flop'larinin cikisidir:
//   host her biti SD saatinin DUSEN kenarinda degistirir, kart YUKSELEN
//   kenarda ornekler, yani karta yarim periyot setup kalir (Phys. Layer Spec
//   Section 6.7). Bu modulde bir kez daha clk ile kaydetmek o yarim periyodu
//   bir clk cevrimi kadar kemirir ve nominal oranda (100 MHz sistem / 50 MHz
//   SD, yani bolme = 2) yarim periyot ZATEN bir clk cevrimidir: kayit, veriyi
//   tam kartin ornekleme kenarina tasir ve setup'i sifirlar. Bu yuzden pede
//   giden deger flop -> ped olarak gecer; yolda kombinasyonel mantik yoktur
//   ve her pad cikisi gene de dogrudan bir flop'tan surulur.
//
//   ---------------------------------------------------------------------------
//   GIRIS YOLU: ORNEKLEME FAZI (R-DEG-2)
//   ---------------------------------------------------------------------------
//   Kart cikisini kendi gordugu YUKSELEN kenardan tODLY sonra surer ve bir
//   sonraki yukselen kenara kadar tutar. L1/L2 ise bu modulden gelen degeri
//   yukselen kenarda okur. Araya giren tek flop, pedi SD periyodu icinde
//   secilen bir noktada yakalayan ornekleme flop'udur:
//
//       SD rise (e0)                                   sonraki rise (eN)
//            |                                                |
//            |<-- 1 + SAMPLE_PHASE adet clk cevrimi -->|      |
//            |                                         v      |
//            |                                      YAKALA    v  L1/L2 okur
//
//   Yakalanan deger bir sonraki yakalamaya kadar TUTULUR, yani tuketici
//   kenarda stabildir; ek gecikme getirmez, cunku yukselen kenarda dogrudan
//   ornekleme de ayni biti (onceki periyotta surulen biti) okurdu. Faz
//   yalnizca o bitin pencere icinde NEREDEN okundugunu kaydirir:
//     SAMPLE_PHASE = 0 -> rise + 1 clk  (nominal oranda periyodun ortasi)
//     SAMPLE_PHASE = N -> rise + 1 + N clk
//
//   KAC FAZ VAR. Faz clk periyodu cinsinden kuantalidir (PLL yok): bolme orani
//   N ise periyoda N adet clk kenari sigar, yani kullanilabilir faz 0..N-1'dir.
//   Son faz (N-1) tam bir sonraki yukselen kenara duser -- klasik "posedge'de
//   ornekle" noktasi -- ve dogrulugu kartin tOH tutma suresine baglidir, o
//   yuzden guvenli pencere pratikte 0..N-2'dir:
//     bolme = 2   (100 MHz -> 50 MHz)   : faz 0..1, guvenli olan 0 (periyodun
//                                         ortasi, nominal oranda tek secenek)
//     bolme = 4   (100 MHz -> 25 MHz)   : faz 0..3, guvenli olan 0..2
//     bolme = 255 (baslatma, <=400 kHz) : alan 4 bit oldugu icin 0..15
//   Nominal oranda tek guvenli faz bulunmasi bir eksiklik degil: o faz zaten
//   pencerenin ortasidir. Daha fazla faz isteyen sistem clk'ini yukseltir --
//   RTL degismez (R-DEG-7).
//
//   ORANIN IZIN VERDIGINDEN BUYUK FAZ (SAMPLE_PHASE >= N). Sayac bir sonraki
//   yukselen kenara kadar tukenmezse ornek o kenarda zorla alinir: deger donup
//   kalmaz, akis bir bit kayar ve CRC hata verir. Bu kasten boyle -- Figure 7-1
//   adim 6 SAMPLE_PHASE'i bilerek bozup CRC hatalarinin sayilip toparlanmasini
//   gormek ister. Cok KUCUK faz da (ornek kartin tODLY'sinden once alinirsa)
//   ayni sekilde bir bit kayar, yani her iki yonde de bozuk faz gozlenebilir
//   bir CRC hatasina doner, sessiz bir donmaya degil.
//
//   ---------------------------------------------------------------------------
//   HAT BASINA UC-DURUM
//   ---------------------------------------------------------------------------
//   dat_oe_i hat basinadir (L1'in dat_oe_o'su ile bire bir): maskelenmis bir
//   transferde kullanilmayan hatlar yuksek empedansta kalir ve karta sahte
//   bit gostermez. Hangi hatlarin kullanilacagini system_controller'in
//   lane_en_o'su belirler, L1 onu transfer basinda kilitler, buraya ise
//   coktan cozulmus haliyle oe olarak gelir.
//
//   FAZ 0 sozlesmesi. Reset altinda pad_en_q = 0, yani cmd ve DAT3..DAT0
//   pedlerinin tamami yuksek empedanstadir ve karti kendi pull-up'lari
//   yukarida tutar: surulen hicbir hat karta reset aninda sahte bir start
//   biti gostermez. Yakalama flop'lari da bos seviyeye (1) kurulur, cunku
//   bos hat yukaridadir. sd_clk, kaynagi (clk_controller) reset altinda
//   alcakta park ettigi icin alcakta durur.
//
//   SURME GUCU. Gowin IOBUF'un calisma aninda ayarlanabilir bir surme gucu
//   girisi yoktur; DRIVE ve PULL_MODE ped ozellikleridir ve .cst icinde
//   verilir (Table 2-5). RTL'de bir karsiligi olmadigi icin burada da bir
//   sinyali yoktur -- uydurma bir port dead code olurdu (Section 4.4).
//
//   CFG_PHY'NIN DIGER BITLERI. FORCE_1BIT (bit 4) hat maskesini
//   system_controller'da, FORCE_DS (bit 5) hiz merdivenini ultra_sd_init
//   icinde zorlar: ikisi de protokol kararidir, L0'in isi degildir. Bu modul
//   cfg_phy_i'nin yalnizca SAMPLE_PHASE alanini kullanir.
//
//   Clock domain : clk (sistem). sd_clk_i ayni clk alaninda uretilmis bir
//                  flop cikisidir, bu modulde saat olarak KULLANILMAZ: kenari
//                  senkron olarak algilanir, dolayisiyla CDC yoktur ve
//                  doc/cdc.md'ye yeni satir gerekmez. Pedden gelen veri
//                  kaynak-senkron bir giristir; onu tanimli kilan sey
//                  ornekleme noktasidir (yukarida), senkronizer degil --
//                  ikinci bir flop yalnizca gecikme eklerdi.
//   Reset scheme : rst_n, asenkron assert / senkron deassert (R-CLK-1, R-CLK-4)
//   Implements   : Spec Section 4.2, R-ARCH-2, R-CLK-5 (sifir PLL),
//                  R-DEG-2 (calisma aninda ayarlanabilir SAMPLE_PHASE)
// -----------------------------------------------------------------------------
// Satici primitifi olmayan simulasyonlar (iverilog, test/) icin:
//   +define+ULTRA_SD_NO_VENDOR_PRIM
// Bu durumda IOBUF yerine ayni davranisin davranissal uc-durum modeli surulur.
// Sentez akisinda makro tanimsizdir ve gercek Gowin IOBUF'u ornekleni.
// -----------------------------------------------------------------------------
module ultra_sd_phy_gowin
  import ultra_sd_pkg::*;
(
  input  logic                   clk,
  input  logic                   rst_n,

  // ---- konfigurasyon, register dosyasindan ---------------------------------
  input  logic [CFG_PHY_W-1:0]   cfg_phy_i,     // [3:0] faz, [4] 1bit, [5] DS

  // ---- pede gidecek saat, system_controller'dan ----------------------------
  // Aktif kanal (cmd_clk / line_clk) orada secilir; burada sadece pede baglanir.
  input  logic                   sd_clk_i,

  // ---- L1 ile CMD hatti ----------------------------------------------------
  input  logic                   cmd_out_i,
  input  logic                   cmd_oe_i,      // 1 = host suruyor
  output logic                   cmd_in_o,      // ornekleme fazinda yakalanmis

  // ---- L1 ile DAT hatlari --------------------------------------------------
  input  logic [SD_DATA_LANES-1:0] dat_out_i,
  input  logic [SD_DATA_LANES-1:0] dat_oe_i,   // HAT BASINA, L1.dat_oe_o
  output logic [SD_DATA_LANES-1:0] dat_in_o,

  // ---- SD pedleri ----------------------------------------------------------
  output logic                   sd_clk,
  inout  wire                    sd_cmd,
  inout  wire  [3:0]             sd_dat
);

  // ---------------------------------------------------------------------------
  // Ornekleme fazi ve SD saat kenari algilama
  // ---------------------------------------------------------------------------
  logic [CFG_PHY_PHASE_W-1:0] phase_q;      // CFG_PHY[3:0], kayitli
  logic                       sd_clk_q;     // sd_clk_i'nin bir cevrim gecikmesi
  logic [CFG_PHY_PHASE_W-1:0] phase_cnt_q;  // yakalamaya kalan clk cevrimi
  logic                       samp_pend_q;  // bu periyotta ornek henuz alinmadi

  // Pedin yukselen kenari: ayni clk alaninda uretilmis bir flop cikisi oldugu
  // icin tek flop'luk gecikme kenari tam olarak gosterir.
  logic sd_rise;
  assign sd_rise = sd_clk_i & ~sd_clk_q;

  // Bu clk kenarinda pedi yakala. Uc durum:
  //   * kenarin kendisi + faz 0        -> rise + 1 clk, pencerenin ortasi
  //   * sayac tukendi                  -> rise + 1 + faz clk
  //   * sayac tukenmeden yeni kenar    -> faz orandan buyuk, zorla yakala
  //                                       (bkz. basliktaki "bozuk faz" notu)
  logic samp_en;
  assign samp_en = sd_rise ? ((phase_q == '0) | samp_pend_q)
                           : (samp_pend_q & (phase_cnt_q == '0));

  // ---------------------------------------------------------------------------
  // Yakalama flop'lari ve ped park bayragi
  // ---------------------------------------------------------------------------
  logic                     cmd_in_q;
  logic [SD_DATA_LANES-1:0] dat_in_q;
  logic                     pad_en_q;   // 0 = tum pedler yuksek empedans

  // Pedden okunan ham degerler (IOBUF.O cikislari).
  logic                     cmd_pad_in;
  logic [SD_DATA_LANES-1:0] dat_pad_in;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // ---- FAZ 0 reset degerleri --------------------------------------------
      pad_en_q    <= 1'b0;                      // yuksek empedans, pull-up kazanir
      cmd_in_q    <= 1'b1;                      // kart bos hatti yukarida tutar
      dat_in_q    <= {SD_DATA_LANES{1'b1}};
      phase_q     <= '0;                        // CFG_PHY reset degeri ile ayni
      sd_clk_q    <= 1'b0;                      // kaynak alcakta park eder
      phase_cnt_q <= '0;
      samp_pend_q <= 1'b0;                      // saat kosmadan ornek alinmaz
    end else begin
      // Reset birakildiktan bir cevrim sonra pedler L1/L2'nin oe'sine devredilir.
      pad_en_q <= 1'b1;

      // Faz yalnizca kenarda okundugu icin calisma aninda serbestce
      // degistirilebilir: yeni deger bir sonraki SD periyodunda gecerli olur,
      // surmekte olan bir ornekleme penceresi kaymaz (R-DEG-2).
      phase_q  <= cfg_phy_i[CFG_PHY_PHASE_LSB +: CFG_PHY_PHASE_W];

      sd_clk_q <= sd_clk_i;

      // ---- ornekleme penceresi ---------------------------------------------
      if (sd_rise) begin
        // Faz 0 ise bu kenarda yakaladik, beklenecek bir sey kalmadi.
        samp_pend_q <= (phase_q != '0);
        phase_cnt_q <= (phase_q == '0) ? '0
                                       : (phase_q - CFG_PHY_PHASE_W'(1));
      end else if (samp_pend_q) begin
        if (phase_cnt_q != '0) begin
          phase_cnt_q <= phase_cnt_q - CFG_PHY_PHASE_W'(1);
        end else begin
          samp_pend_q <= 1'b0;                  // ornek bu kenarda alindi
        end
      end

      // ---- pedlerin yakalanmasi --------------------------------------------
      // Yalnizca secilen noktada guncellenir, araligin tamaminda tutulur:
      // tuketici (L1/L2) yukselen kenarda stabil bir deger gorur.
      if (samp_en) begin
        cmd_in_q <= cmd_pad_in;
        dat_in_q <= dat_pad_in;
      end
    end
  end

  assign cmd_in_o = cmd_in_q;
  assign dat_in_o = dat_in_q;

  // ---------------------------------------------------------------------------
  // Uc-durum kontrolu. oe HAT BASINA cozulur ve reset altinda park bayragi ile
  // maskelenir; surulen DEGER maskelenmez, boylece pede giden veri yolunda
  // kombinasyonel mantik kalmaz (bkz. basliktaki "cikis yolu" notu).
  // ---------------------------------------------------------------------------
  logic                     cmd_oe;
  logic [SD_DATA_LANES-1:0] dat_oe;

  assign cmd_oe = pad_en_q & cmd_oe_i;
  assign dat_oe = {SD_DATA_LANES{pad_en_q}} & dat_oe_i;

  // ---------------------------------------------------------------------------
  // Saat pedi. Uretim system_controller'da; burada yolda mantik yok, gelen
  // saat dogrudan pede baglanir. Reset altinda kaynak alcakta park ettigi
  // icin ped de alcakta durur.
  // ---------------------------------------------------------------------------
  assign sd_clk = sd_clk_i;

  // ---------------------------------------------------------------------------
  // Pedler. Satici primitifinin gectigi TEK yer (R-ARCH-2). Gowin IOBUF'ta
  // OEN AKTIF ALCAKTIR: OEN = 0 iken ped surulur, 1 iken yuksek empedanstadir.
  // Dort DAT pedi generate ile ornekleni (R-ARCH-5, kopyala-yapistir yok).
  // ---------------------------------------------------------------------------
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

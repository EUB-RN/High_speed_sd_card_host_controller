// -----------------------------------------------------------------------------
// ultra_sd_line
//   Purpose      : L1. SADECE DAT hatlari. Bir blogu hatlara paketler
//                  (yazma) ve hatlardan cozer (okuma), start / end cerceve
//                  bitlerini uretir, hat basina CRC16 tutar ve yazmadan
//                  sonra kartin CRC durum token'ini okur. CMD hatti bu
//                  modulde YOKTUR (ultra_sd_cmd'in isi), komut siralamasi
//                  YOKTUR, satici primitifi YOKTUR.
//
//   ---------------------------------------------------------------------------
//   Mimari: TEK FSM, iki kenarda veri yolu
//   ---------------------------------------------------------------------------
//                  Kontrol TEK parcadir ve YUKSELEN kenarda saatlenir:
//                  durum, sayaclar, genislik kilidi, CRC toplayicilari ve
//                  tum alma yolu burada. Yazma yolunun pedlere bakan ucu
//                  (surulen deger, output-enable ve kelime kaydirma kaydi)
//                  DUSEN kenarda saatlenir ve FSM'in urettigi durum /
//                  enable sinyalleri ile surulur; kendi durum makinesi
//                  YOKTUR.
//
//                    posedge : FSM + sayaclar + CRC + RX veri yolu
//                    negedge : dat_out_q, dat_oe_q, tx_sh_q (sadece kayit)
//
//                  Her iki yon ayni anda calismadigi icin (dir_i birini
//                  secer) kontrolu ikiye bolmek, durumu ve sayaclari bos
//                  yere cogaltmak demekti. Tek FSM bunu ortadan kaldirir ve
//                  tx_busy / rx_busy / done darbelerini tek saat alanina
//                  tasir, ustteki FSM icin de tek alan kalir.
//
//                  Kenarlar arasi yollar yarim periyottur: FSM cikislari
//                  yukselen kenarda kurulur ve bir sonraki dusen kenarda
//                  kullanilir; dusen kenarda surulen bit de ortasindaki
//                  yukselen kenarda (kartin ornekleme ani) CRC'ye katlanir.
//                  Bunlar .sdc icinde half-cycle olarak kisitlanmalidir.
//
//                  Durum degiskeni "su an HAT UZERINDE olan hucre"yi
//                  anlatir. Yukselen kenarda okunan degeri o hucredir;
//                  ayni kenarda yapilan atama ise bir sonraki hucreyi
//                  tarif eder ve dusen kenar onu oldugu gibi uygular.
//
//   ---------------------------------------------------------------------------
//   CRC16: TEK takim, dort paralel hat
//   ---------------------------------------------------------------------------
//                  Hat basina bir CRC16 vardir, YON basina degil: dort
//                  ultra_sd_crc16 ornegi ve dort 16 bitlik toplayici,
//                  yazma ve okumada ORTAK kullanilir. Besleme bir mux'tur:
//                  yazarken hatta surulen bit (dat_out_q), okurken hattan
//                  gelen bit (dat_in_i) -- iki durumda da "o anda hat
//                  uzerindeki bit" katlanir, yani kartin gordugu ile ayni
//                  akistir.
//
//                  Her hat kendi bit akisinin CRC'sini tasir; yeniden
//                  birlestirilmis bayt akisinin TEK CRC'si DEGIL (hazard
//                  D-1). CRC yalnizca yuk bitlerini kapsar; start ve end
//                  bitleri kapsam disidir.
//
//                  Ayrica CRC icin ikinci bir kaydirma/saklama kaydi da
//                  tutulmaz, toplayicinin kendisi kullanilir:
//                    * TX : yuk bittiginde toplayici artik kalandir. Sifir
//                           beslenerek 16 saat boyunca tepeden hatta
//                           kaydirilir.
//                    * RX : karttan gelen 16 CRC biti durdurulmak yerine
//                           ayni toplayiciya KATLANMAYA devam eder. CRC16
//                           GF(2) uzerinde lineer, init = 0 ve son XOR yok
//                           oldugundan mesajin ardindan kendi kalanini
//                           beslemek toplayiciyi SIFIRA goturur. Dogrulama
//                           boylece "kalan sifir mi" kontrolune iner: ne
//                           alinan CRC'yi saklayan kayit ne de 4 x 16
//                           bitlik karsilastirici gerekir.
//
//   ---------------------------------------------------------------------------
//   Veri arayuzu ve cerceve
//   ---------------------------------------------------------------------------
//                  VERI ARAYUZU 32 BIT. Ustteki katman (AXI-Stream / DMA
//                  yolu) 32 bitlik kelimelerle konusur; bayt bazli bir port
//                  yoktur, seri cevrim bu modulun icinde kalir.
//
//                  KELIME ICI BAYT SIRASI. SD hatti bayt icinde MSB-first
//                  surer, bu zorunlu. Kelimenin hangi baytinin hatta ONCE
//                  gittigi WORD_LITTLE_ENDIAN ile secilir:
//                    1 (varsayilan) : tx_data_i[7:0] once, sonra [15:8],
//                                     [23:16], [31:24] -- AXI-Stream /
//                                     bellek sirasi, repo'daki axis yolu.
//                    0              : tx_data_i[31:24] once -- big endian.
//                  RX tarafinda ayni sira tersten uygulanir, yani yazilan
//                  kelime okundugunda birebir geri gelir.
//
//                  HAT GENISLIGI. SD veri yolunun yalnizca IKI genisligi
//                  vardir:
//                    4'b0001 -> 1-bit mod, yalniz DAT0   (1 bit / saat)
//                    4'b1111 -> 4-bit mod, DAT3..DAT0    (4 bit / saat)
//                  lane_en_i bunlardan birini secer; baska bir desen
//                  tanimli degildir ve guvenli taraf olan 1-bit moda
//                  dusurulur. Genislik transfer basinda bir kez kilitlenir.
//
//                  PAKETLEME. 4-bit modda her saatte bir nibble surulur ve
//                  nibble'in en anlamli biti EN YUKSEK hatta gider:
//                  DAT3 = suren baytin bit7'si, DAT0 = bit4. 1-bit modda
//                  yalniz DAT0, bit basina bir saat. Iki halde de bir
//                  kelime tam sayida saate oturur (8 ya da 32 grup).
//
//                  FAZ 0 sozlesmesi. Reset altinda hat BOS: dat_oe_o = 0
//                  (pedler yuksek empedans, kartin pull-up'lari hatti
//                  yukari ceker), surulen degerler 1, sayaclar sifir, CRC
//                  toplayicilar CRC16_INIT. Reset birakildiktan sonra FSM
//                  start vermeden hicbir start biti uretilmez.
//
//   Clock domain : line_clk. Kontrol ve RX yukselen kenar, ped surme yolu
//                  dusen kenar; aralarindaki yollar yarim periyot.
//   Reset scheme : rst_n, asenkron assert / senkron deassert
//   Implements   : Spec Section 4.2 (katman sorumluluklari), Appendix A
//                  Table A-3 (CRC16 / hat), R-FUNC-9 (akis halinde CRC),
//                  R-ARCH-5 (dort hat generate ile, kopyala-yapistir yok)
//
//   ---------------------------------------------------------------------------
//   El sikisma sozlesmesi (FSM tarafi)
//   ---------------------------------------------------------------------------
//   * start_i baska bir saat alanindan gelir (sistem FSM'i) ve iki flop'luk
//     senkronizatorden gecer, bu yuzden SEVIYE olarak verilmeli: tx_busy_o /
//     rx_busy_o yukselene kadar yukarida tutulmali, sonra indirilmeli.
//   * dir_i = 1 yazma, 0 okuma. start_i ile birlikte stabil olmali.
//   * Yazma veri besleme: tx_data_i FWFT (first-word-fall-through) okuma
//     portu gibi davranmali -- siradaki kelime gecerli beklenir, tx_take_o
//     ise tuketimin oldugu DUSEN kenarda yukarida olan bir pop darbesidir.
//     Kaynak sistem saatindeyse arada bir async_fifo bulunmali; o fifo'nun
//     okuma saati ~line_clk'tir.
//   * Okuma yonunde start biti karttan gelir: start_i yalnizca aliciyi
//     silahlandirir, cerceve DAT0 asagi cekildiginde baslar. Timeout bu
//     modulde DEGIL, ustteki FSM'de sayilir.
//   * Yazma sonrasi CRC durum token'i (CRC status) BU MODULDE okunur --
//     bit seviyesinde cerceveleme L1'in isidir. End bitinden sonra pedler
//     birakilir, kart DAT0 uzerinde "0 sss 1" token'ini surer ve sonuc
//     tx_status_o / tx_status_ok_o ile raporlanir. tx_done_o artik end
//     bitinde degil, TOKEN TAMAMLANDIGINDA (ya da zaman asiminda)
//     darbelenir; tx_busy_o o ana kadar yukarida kalir.
//   * Token'i beklemek sinirlidir: STAT_WAIT_MAX hucre icinde start biti
//     gelmezse tx_status_tmo_o ile birlikte done verilir, modul asla
//     kilitlenmez. Programlama (busy) suresi ise burada SAYILMAZ: kart
//     DAT0'i asagida tutarken card_busy_o yukarida kalir, kac saat
//     beklenecegine ve zaman asimina ustteki FSM karar verir.
// -----------------------------------------------------------------------------
module ultra_sd_line
  import ultra_sd_pkg::*;
#(
  // Bir cercevede tasinan yuk bayti. Varsayilan SD blok boyu. 4'un kati
  // olmali: veri arayuzu 32 bittir.
  parameter int XFER_BYTES = BLOCK_BYTES,
  // 1 = kelimenin [7:0] bayti hatta once gider (AXI-Stream / bellek sirasi).
  parameter bit          WORD_LITTLE_ENDIAN = 1'b1,
  // Yazmanin end bitinden sonra CRC durum token'inin start biti icin
  // beklenecek en fazla hucre. Spec en erken 2 saat sonra der; buradaki
  // pay toleranstir, asilirsa zaman asimi bildirilir.
  parameter int STAT_WAIT_MAX = 8
) (
  // DAT hatlarinin uretilmis saati (clk_controller.line_clk_o).
  input  logic                     line_clk,
  input  logic                     rst_n,

  // ---- FSM kontrolu --------------------------------------------------------
  input  logic [SD_DATA_LANES-1:0] lane_en_i,   // 0001 = 1-bit, 1111 = 4-bit
  input  logic                     dir_i,       // 1 = yazma, 0 = okuma
  input  logic                     start_i,     // seviye, busy yukselene kadar

  // ---- Yazma kanali --------------------------------------------------------
  input  logic [31:0]              tx_data_i,   // FWFT: siradaki kelime gecerli
  output logic                     tx_take_o,   // pop darbesi, dusen kenarda
  output logic                     tx_busy_o,
  output logic                     tx_done_o,      // token bitince tek darbe
  output logic [2:0]               tx_status_o,    // ham token bitleri (sss)
  output logic                     tx_status_ok_o, // sss == 010 (kabul)
  output logic                     tx_status_tmo_o,// token hic gelmedi

  // ---- Okuma kanali --------------------------------------------------------
  output logic [31:0]              rx_data_o,
  output logic                     rx_valid_o,  // kelime basina tek darbe
  output logic                     rx_busy_o,
  output logic                     rx_done_o,   // tek saat darbesi
  output logic                     rx_crc_ok_o, // rx_done_o ile gecerli

  // ---- kart mesgul (programlama) -------------------------------------------
  // Hat bostayken DAT0 asagida ise kart programliyor demektir. Sure burada
  // sayilmaz; bekleme ve zaman asimi ustteki FSM'in isi.
  output logic                     card_busy_o,

  // ---- PHY hat arayuzu -----------------------------------------------------
  // oe hat basinadir: kullanilmayan hatlar maskelenmis transferde de yuksek
  // empedansta kalir, karta sahte bit gostermez.
  output logic [SD_DATA_LANES-1:0] dat_out_o,
  output logic [SD_DATA_LANES-1:0] dat_oe_o,
  input  logic [SD_DATA_LANES-1:0] dat_in_i
);

  // ---------------------------------------------------------------------------
  // Geometri
  // ---------------------------------------------------------------------------
  localparam int WORD_W     = 32;
  localparam int XFER_WORDS = XFER_BYTES / 4;

  localparam int WORD_CNT_W = $clog2(XFER_WORDS + 1);
  localparam int GRP_CNT_W  = $clog2(WORD_W + 1);       // en fazla 32
  localparam int CRC_CNT_W  = $clog2(CRC16_W);

  // Iki genislik, iki grup boyu: 4-bit modda saat basina bir nibble,
  // 1-bit modda bir bit.
  localparam int WIDE_BITS   = 4;
  localparam int NARROW_BITS = 1;

  // Simulasyon zamani sozlesme kontrolu: 32 bitlik arayuz kismi kelime
  // tasimaz. Sentezlenen mantik degil, yalnizca elaborasyon kontrolu.
  initial begin
    if ((XFER_BYTES % 4) != 0) begin
      $fatal(1, "ultra_sd_line: XFER_BYTES (%0d) 4'un kati olmali", XFER_BYTES);
    end
  end

  // lane_en_i -> 4-bit mod mu? Yalnizca 4'b1111 4-bit moddur; her sey
  // (sifir ya da yarim maske dahil) guvenli taraf olan 1-bit moda duser.
  function automatic logic is_wide(logic [SD_DATA_LANES-1:0] m);
    is_wide = (m == 4'b1111);
  endfunction

  // Aktif hat maskesi. CRC toplama ve oe bunu kullanir.
  function automatic logic [SD_DATA_LANES-1:0] lane_mask(logic wide);
    lane_mask = wide ? 4'b1111 : 4'b0001;
  endfunction

  // Bir kelime kac saat suruyor: 32 / genislik.
  function automatic logic [GRP_CNT_W-1:0] groups_per_word(logic wide);
    groups_per_word = wide ? GRP_CNT_W'(WORD_W / WIDE_BITS)
                           : GRP_CNT_W'(WORD_W / NARROW_BITS);
  endfunction

  // Kelime <-> gonderim sirasi cevrimi. Kaydirma kaydi her zaman en ustteki
  // bitten suruldugu icin, "hatta once giden bayt" en uste yerlestirilir.
  // Fonksiyon kendi tersidir: ayni swizzle RX tarafinda da kullanilir.
  function automatic logic [WORD_W-1:0] word_swizzle(logic [WORD_W-1:0] d);
    if (WORD_LITTLE_ENDIAN) begin
      word_swizzle = {d[7:0], d[15:8], d[23:16], d[31:24]};
    end else begin
      word_swizzle = d;
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Durum: "su an hat uzerinde olan hucre". Yukselen kenarda okunan deger o
  // hucreyi, ayni kenarda yazilan deger bir sonraki hucreyi anlatir.
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    CELL_IDLE,      // hat birakilmis
    CELL_TX_START,  // start biti suruluyor
    CELL_TX_DATA,   // yuk grubu suruluyor
    CELL_TX_CRC,    // CRC biti suruluyor
    CELL_TX_END,       // end biti suruluyor
    CELL_TX_STAT_ARM,  // pedler birakildi, token start biti bekleniyor
    CELL_TX_STAT,      // token'in 3 durum biti orneklenior
    CELL_TX_STAT_END,  // token end biti; sonuc raporlanir
    CELL_RX_ARM,    // silahli, karttan start biti bekleniyor
    CELL_RX_DATA,   // yuk grubu orneklenior
    CELL_RX_CRC,    // CRC biti orneklenior
    CELL_RX_END     // end biti; cerceve bitti, sonuc raporlanir
  } cell_e;

  cell_e                     cell_q;
  logic                      wide_q;     // kilitlenmis genislik: 1 = 4-bit
  logic [SD_DATA_LANES-1:0]  mask_q;     // kilitlenmis aktif hat maskesi
  logic [GRP_CNT_W-1:0]      grp_q;      // bu kelimede kalan grup (bu hucre dahil)
  logic [WORD_CNT_W-1:0]     word_q;     // islenen kelime indeksi
  logic [CRC_CNT_W-1:0]      crc_cnt_q;
  logic [1:0]                start_sync_q;
  logic                      dir_sync_q;

  // Hat basina TEK CRC toplayici: iki yon de bunu kullanir.
  logic [CRC16_W-1:0]        crc_q [SD_DATA_LANES];
  logic [CRC16_W-1:0]        crc_d [SD_DATA_LANES];

  // RX veri yolu
  logic [WORD_W-2:0]         rx_sh_q;    // tam kelime rx_sh_next uzerinde olusur
  logic [WORD_W-1:0]         rx_data_q;
  logic                      rx_valid_q;
  logic                      rx_done_q;
  logic                      rx_crc_ok_q;
  logic                      tx_done_q;
  logic [2:0]                stat_sh_q;    // token kaydirma
  logic [2:0]                tx_status_q;
  logic                      tx_status_ok_q;
  logic                      tx_status_tmo_q;
  logic                      card_busy_q;

  // TX veri yolu, dusen kenar
  logic [WORD_W-1:0]         tx_sh_q;
  logic [SD_DATA_LANES-1:0]  dat_out_q;
  logic [SD_DATA_LANES-1:0]  dat_oe_q;

  // ---------------------------------------------------------------------------
  // Hucre tipi yardimcilari
  // ---------------------------------------------------------------------------
  logic cell_is_tx;
  logic cell_is_rx;
  assign cell_is_tx = (cell_q == CELL_TX_START)    || (cell_q == CELL_TX_DATA) ||
                      (cell_q == CELL_TX_CRC)      || (cell_q == CELL_TX_END)  ||
                      (cell_q == CELL_TX_STAT_ARM) || (cell_q == CELL_TX_STAT) ||
                      (cell_q == CELL_TX_STAT_END);
  assign cell_is_rx = (cell_q == CELL_RX_ARM)   || (cell_q == CELL_RX_DATA) ||
                      (cell_q == CELL_RX_CRC)   || (cell_q == CELL_RX_END);

  logic word_last;   // bu hucre kelimenin son grubu
  logic block_last;  // bu kelime blogun sonuncusu
  assign word_last  = (grp_q == GRP_CNT_W'(1));
  assign block_last = (word_q == WORD_CNT_W'(XFER_WORDS - 1));

  // ---------------------------------------------------------------------------
  // CRC: dort hat, tek takim. Besleme mux'u -- o anda HAT UZERINDEKI bit.
  // Yazarken dusen kenarda surulen deger, okurken pedden gelen deger.
  // ---------------------------------------------------------------------------
  logic [SD_DATA_LANES-1:0] crc_bit;
  assign crc_bit = cell_is_tx ? dat_out_q : dat_in_i;

  for (genvar l = 0; l < SD_DATA_LANES; l++) begin : g_crc
    ultra_sd_crc16 #(
      .IN_WIDTH (1)
    ) u_crc16 (
      .crc_i  (crc_q[l]),
      .data_i (crc_bit[l]),
      .crc_o  (crc_d[l])
    );
  end

  // Yuk hucresi: CRC katlanir. TX'in CRC hucrelerinde katlama YOK (kendi
  // kalanini suruyor), RX'in CRC hucrelerinde VAR (kalani sifira goturur).
  logic crc_fold_en;
  logic crc_shift_en;
  assign crc_fold_en  = (cell_q == CELL_TX_DATA) || (cell_q == CELL_RX_DATA) ||
                        (cell_q == CELL_RX_CRC);
  assign crc_shift_en = (cell_q == CELL_TX_CRC);

  // Mesaj + kendi kalani katlandiktan sonra toplayici sifir olmali.
  logic rx_crc_zero;
  always_comb begin
    rx_crc_zero = 1'b1;
    for (int i = 0; i < SD_DATA_LANES; i++) begin
      if (mask_q[i] && (crc_q[i] != '0)) rx_crc_zero = 1'b0;
    end
  end

  // ---------------------------------------------------------------------------
  // RX kaydirma: bu saatte orneklenen grubun MSB'si en yuksek aktif hattan.
  // ---------------------------------------------------------------------------
  logic [WORD_W-1:0] rx_sh_next;
  always_comb begin
    if (wide_q) begin
      rx_sh_next = {rx_sh_q[WORD_W-1-WIDE_BITS:0], dat_in_i[WIDE_BITS-1:0]};
    end else begin
      rx_sh_next = {rx_sh_q, dat_in_i[0]};
    end
  end

  // ---------------------------------------------------------------------------
  // TEK FSM -- yukselen kenar. Kontrol, sayaclar, CRC ve tum RX yolu.
  // ---------------------------------------------------------------------------
  always_ff @(posedge line_clk or negedge rst_n) begin
    if (!rst_n) begin
      cell_q       <= CELL_IDLE;
      wide_q       <= 1'b0;
      mask_q       <= 4'b0001;
      grp_q        <= '0;
      word_q       <= '0;
      crc_cnt_q    <= '0;
      start_sync_q <= '0;
      dir_sync_q   <= 1'b0;
      rx_sh_q      <= '0;
      rx_data_q    <= '0;
      rx_valid_q   <= 1'b0;
      rx_done_q    <= 1'b0;
      rx_crc_ok_q  <= 1'b0;
      tx_done_q       <= 1'b0;
      stat_sh_q       <= '0;
      tx_status_q     <= '0;
      tx_status_ok_q  <= 1'b0;
      tx_status_tmo_q <= 1'b0;
      card_busy_q     <= 1'b0;
      for (int i = 0; i < SD_DATA_LANES; i++) begin
        crc_q[i] <= CRC16_INIT;
      end
    end else begin
      // ---- giris senkronizasyonu (sistem FSM'i -> bu alan) ----------------
      start_sync_q <= {start_sync_q[0], start_i};
      dir_sync_q   <= dir_i;

      rx_valid_q <= 1'b0;
      rx_done_q  <= 1'b0;
      tx_done_q  <= 1'b0;

      // Hat bostayken DAT0 asagida = kart programliyor.
      card_busy_q <= (cell_q == CELL_IDLE) && !dat_in_i[0];

      // ---- CRC: hat uzerindeki biti katla ya da kalani disari kaydir -----
      for (int i = 0; i < SD_DATA_LANES; i++) begin
        if (mask_q[i]) begin
          if (crc_fold_en) begin
            crc_q[i] <= crc_d[i];
          end else if (crc_shift_en) begin
            crc_q[i] <= {crc_q[i][CRC16_W-2:0], 1'b0};
          end
        end
      end

      // ---- hucre siralamasi ----------------------------------------------
      case (cell_q)
        // ---------------------------------------------------------------
        CELL_IDLE: begin
          if (start_sync_q[1]) begin
            // Genislik burada bir kez kilitlenir.
            wide_q <= is_wide(lane_en_i);
            mask_q <= lane_mask(is_wide(lane_en_i));
            word_q <= '0;
            for (int i = 0; i < SD_DATA_LANES; i++) begin
              crc_q[i] <= CRC16_INIT;
            end
            cell_q <= dir_sync_q ? CELL_TX_START : CELL_RX_ARM;
          end
        end

        // ---------------------------------------------------------------
        // Start biti hatta; siradaki hucre ilk yuk grubu.
        CELL_TX_START: begin
          grp_q  <= groups_per_word(wide_q);
          cell_q <= CELL_TX_DATA;
        end

        // ---------------------------------------------------------------
        CELL_TX_DATA: begin
          if (!word_last) begin
            grp_q <= grp_q - GRP_CNT_W'(1);
          end else if (!block_last) begin
            // Siradaki kelime dusen kenarda zaten yuklendi (tx_take_o).
            grp_q  <= groups_per_word(wide_q);
            word_q <= word_q + WORD_CNT_W'(1);
          end else begin
            // Son yuk hucresi: toplayici bu kenarda kalana donusuyor,
            // bundan sonra dogrudan hatta kaydirilir.
            crc_cnt_q <= CRC_CNT_W'(CRC16_W - 1);
            cell_q    <= CELL_TX_CRC;
          end
        end

        // ---------------------------------------------------------------
        CELL_TX_CRC: begin
          if (crc_cnt_q == '0) begin
            cell_q <= CELL_TX_END;
          end else begin
            crc_cnt_q <= crc_cnt_q - CRC_CNT_W'(1);
          end
        end

        // ---------------------------------------------------------------
        // End biti hatta. Pedler bir sonraki dusen kenarda birakilir ve
        // kartin CRC durum token'i beklenmeye baslar.
        CELL_TX_END: begin
          tx_status_tmo_q <= 1'b0;
          crc_cnt_q       <= CRC_CNT_W'(STAT_WAIT_MAX - 1);
          cell_q          <= CELL_TX_STAT_ARM;
        end

        // ---------------------------------------------------------------
        // Token start biti: kart DAT0'i asagi ceker. Bekleme sinirlidir,
        // boylece token hic gelmezse modul kilitlenmez.
        CELL_TX_STAT_ARM: begin
          if (!dat_in_i[0]) begin
            crc_cnt_q <= CRC_CNT_W'(2);     // ardindan 3 durum biti
            cell_q    <= CELL_TX_STAT;
          end else if (crc_cnt_q == '0) begin
            tx_status_tmo_q <= 1'b1;
            tx_status_ok_q  <= 1'b0;
            tx_done_q       <= 1'b1;
            cell_q          <= CELL_IDLE;
          end else begin
            crc_cnt_q <= crc_cnt_q - CRC_CNT_W'(1);
          end
        end

        // ---------------------------------------------------------------
        // Uc durum biti, MSB-first: 010 kabul, 101 CRC hatasi, 110 yazma
        // hatasi.
        CELL_TX_STAT: begin
          stat_sh_q <= {stat_sh_q[1:0], dat_in_i[0]};
          if (crc_cnt_q == '0) begin
            cell_q <= CELL_TX_STAT_END;
          end else begin
            crc_cnt_q <= crc_cnt_q - CRC_CNT_W'(1);
          end
        end

        // ---------------------------------------------------------------
        // Token end biti. Sonuc burada raporlanir; programlama suresi
        // (busy) card_busy_o ile disariya birakilir.
        CELL_TX_STAT_END: begin
          tx_status_q    <= stat_sh_q;
          tx_status_ok_q <= (stat_sh_q == 3'b010);
          tx_done_q      <= 1'b1;
          cell_q         <= CELL_IDLE;
        end

        // ---------------------------------------------------------------
        // Start biti karttan gelir: DAT0 asagi cekildiginde cerceve baslar.
        CELL_RX_ARM: begin
          if (!dat_in_i[0]) begin
            rx_sh_q <= '0;
            grp_q   <= groups_per_word(wide_q);
            word_q  <= '0;
            cell_q  <= CELL_RX_DATA;
          end
        end

        // ---------------------------------------------------------------
        CELL_RX_DATA: begin
          rx_sh_q <= rx_sh_next[WORD_W-2:0];
          if (!word_last) begin
            grp_q <= grp_q - GRP_CNT_W'(1);
          end else begin
            // Kelime tamamlandi: gonderim sirasindan kelime sirasina
            // cevrilip tek darbe ile ustte sunulur.
            rx_data_q  <= word_swizzle(rx_sh_next);
            rx_valid_q <= 1'b1;
            if (!block_last) begin
              grp_q  <= groups_per_word(wide_q);
              word_q <= word_q + WORD_CNT_W'(1);
            end else begin
              crc_cnt_q <= CRC_CNT_W'(CRC16_W - 1);
              cell_q    <= CELL_RX_CRC;
            end
          end
        end

        // ---------------------------------------------------------------
        // Karttan gelen 16 CRC biti de ayni toplayiciya katlanir; dogru bir
        // cercevede bu islem kalani sifira goturur.
        CELL_RX_CRC: begin
          if (crc_cnt_q == '0) begin
            cell_q <= CELL_RX_END;
          end else begin
            crc_cnt_q <= crc_cnt_q - CRC_CNT_W'(1);
          end
        end

        // ---------------------------------------------------------------
        // End biti hatta. Kalan kontrolu bu kenarda; sonuc rx_done_o ile
        // birlikte, yani cerceve fiziksel olarak bittikten sonra verilir.
        CELL_RX_END: begin
          rx_crc_ok_q <= rx_crc_zero;
          rx_done_q   <= 1'b1;
          cell_q      <= CELL_IDLE;
        end

        default: cell_q <= CELL_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // TX veri yolu -- DUSEN kenar. Kendi durumu yok: yukarida kurulan cell_q,
  // mask_q, grp_q ve crc_q'yu oldugu gibi uygular.
  // ---------------------------------------------------------------------------

  // Bu hucrede hatlara surulecek grup. Grubun MSB'si en yuksek aktif hatta.
  logic [SD_DATA_LANES-1:0] grp_bits;
  always_comb begin
    grp_bits = {SD_DATA_LANES{1'b1}};               // kullanilmayan hat bos
    if (wide_q) begin
      grp_bits = tx_sh_q[WORD_W-1 -: WIDE_BITS];    // DAT3 = MSB
    end else begin
      grp_bits[0] = tx_sh_q[WORD_W-1];              // yalniz DAT0
    end
  end

  // Toplayicinin tepesi: CRC hucrelerinde hatta giden bit.
  logic [SD_DATA_LANES-1:0] crc_top;
  for (genvar l = 0; l < SD_DATA_LANES; l++) begin : g_crc_top
    assign crc_top[l] = crc_q[l][CRC16_W-1];
  end

  // Kaydirma miktari: iki sabitten biri, calisma aninda degisken bir
  // kaydirici degil.
  logic [2:0] step;
  assign step = wide_q ? 3'(WIDE_BITS) : 3'(NARROW_BITS);

  // Besleme pop'u: start hucresinde ilk kelime, sonra her kelimenin son
  // grubunu surerken bir sonraki kelime alinir. Dusen kenarda gecerli.
  assign tx_take_o = (cell_q == CELL_TX_START) ||
                     ((cell_q == CELL_TX_DATA) && word_last && !block_last);

  always_ff @(negedge line_clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_sh_q   <= '0;
      dat_out_q <= {SD_DATA_LANES{1'b1}};   // bos seviye
      dat_oe_q  <= '0;                      // yuksek empedans
    end else begin
      case (cell_q)
        CELL_TX_START: begin
          dat_out_q <= ~mask_q;             // start biti: aktif hatlar asagi
          dat_oe_q  <= mask_q;
          tx_sh_q   <= word_swizzle(tx_data_i);
        end
        CELL_TX_DATA: begin
          dat_out_q <= (grp_bits & mask_q) | ~mask_q;
          dat_oe_q  <= mask_q;
          tx_sh_q   <= tx_take_o ? word_swizzle(tx_data_i) : (tx_sh_q << step);
        end
        CELL_TX_CRC: begin
          dat_out_q <= (crc_top & mask_q) | ~mask_q;
          dat_oe_q  <= mask_q;
        end
        CELL_TX_END: begin
          dat_out_q <= {SD_DATA_LANES{1'b1}};   // end biti
          dat_oe_q  <= mask_q;
        end
        default: begin
          dat_out_q <= {SD_DATA_LANES{1'b1}};
          dat_oe_q  <= '0;                      // okuma ve bosta: birak
        end
      endcase
    end
  end

  assign dat_out_o   = dat_out_q;
  assign dat_oe_o    = dat_oe_q;

  assign tx_busy_o       = cell_is_tx;
  assign tx_done_o       = tx_done_q;
  assign tx_status_o     = tx_status_q;
  assign tx_status_ok_o  = tx_status_ok_q;
  assign tx_status_tmo_o = tx_status_tmo_q;
  assign card_busy_o     = card_busy_q;

  assign rx_data_o   = rx_data_q;
  assign rx_valid_o  = rx_valid_q;
  assign rx_busy_o   = cell_is_rx;
  assign rx_done_o   = rx_done_q;
  assign rx_crc_ok_o = rx_crc_ok_q;

endmodule

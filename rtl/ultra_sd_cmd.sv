// -----------------------------------------------------------------------------
// ultra_sd_cmd
//   Purpose      : CMD hattinin tamami: 48-bit komut cercevesinin uretilmesi
//                  ve surulmesi, yanit cercevesinin yakalanmasi ve CRC7
//                  dogrulamasi, CMD55 + ACMD siralamasi, NCR zaman asimi,
//                  NCC bosluk penceresi ve yeniden deneme politikasi.
//                  Satici primitifi YOK (uc-durum kontrolu L0'da), AXI
//                  sinyali YOK, kullanici FIFO'su YOK.
//
//   IKI KANAL     : Modul tek bir saatin (cmd_clk) iki kenariyla beslenen iki
//                   kanaldan olusur. Bolunmus SD saati karta cikan saattir,
//                   yani kenarlarin anlami protokol tarafindan sabitlenmistir
//                   (Phys. Layer Spec Section 6.7, Figure 6-2):
//
//                     * YAZMA KANALI  -- negedge cmd_clk
//                       Host CMD uzerinde bit degistirmek icin DUSEN kenari
//                       kullanir. Kart girisini YUKSELEN kenarda ornekler;
//                       dusen kenarda surmek karta tam bir yarim periyot
//                       setup, bir yarim periyot hold birakir.
//
//                     * OKUMA KANALI  -- posedge cmd_clk
//                       Kart kendi cikisini yukselen kenardan sonra (tODLY)
//                       surer ve bir sonraki yukselen kenara kadar tutar.
//                       Dolayisiyla host'un bir bit onceki degeri yakalamasi
//                       icin dogru nokta YUKSELEN kenardir: setup = periyot -
//                       tODLY, hold = kartin tOH'u. Ince ayar (ornekleme fazi)
//                       L0'da, CFG_PHY[3:0] ile yapilir.
//
//                   Iki kanal AYNI saatin iki kenari oldugu icin aralarindaki
//                   tx_go / tx_done el sikismasi bir CDC DEGIL, yarim-periyot
//                   (half-cycle) senkron yoldur; doc/cdc.md'ye yeni bir satir
//                   gerektirmez. .sdc icinde cmd_clk bir generated clock olarak
//                   tanimlidir, her iki kenar da ayni generated clock'a aittir.
//
//   Clock domain : cmd_clk (clk_controller'in urettigi CMD saati).
//                  req_* / rsp_* arayuzu seviye tabanli (valid/ready) tutulur:
//                  cmd_clk, clk'in tamsayi bolunmusu oldugu icin karsi taraf
//                  istegi birkac clk cevrimi boyunca sabit tutar ve yaniti
//                  seviye olarak okur -- tek cevrimlik darbe YOKTUR.
//   Reset scheme : rst_n, asenkron assert / senkron deassert (R-CLK-1).
//                  Reset altinda her iki kanal da BOS: cmd_oe = 0 (hat
//                  birakilmis, kart pull-up'i kazanir), surulen deger 1,
//                  sayaclar duruk, err_o = ERR_OK, STAT_* sayaclari sifir.
//   Implements   : Spec Section 6, Appendix A Table A-1 / A-2 / A-3,
//                  R-FUNC-16, R-FUNC-17 (sinirli ve isimlendirilmis timeout),
//                  Table 5-2 (STAT_BUSY, STAT_RETRY), Table 5-3 (hata kodlari)
// -----------------------------------------------------------------------------
// Not: paket importu modul govdesinde; parametre listesinden ONCE yapilan
// header importunu iverilog kabul etmiyor.
module ultra_sd_cmd #(
  // R-FUNC-16: her bekleme sinirli ve isimlendirilmis olmak zorunda.
  // NCR: komutun son bitinden yanitin start bitine kadar izin verilen en
  // uzun pencere. SD spec: en fazla 64 saat cevrimi.
  parameter int NCR_TIMEOUT_CLK = 64,
  // NCC: iki komut arasinda hattin bos (yuksek) kalmasi gereken en az saat
  // cevrimi. SD spec: en az 8.
  parameter int NCC_GAP_CLK     = 8,
  // Tasima katmani hatasinda (CRC / timeout) komutun kac kez tekrarlanacagi.
  parameter int CMD_RETRIES     = 3
) (
  // ---- iki kanali besleyen saat ve reset -----------------------------------
  input  logic                      cmd_clk,   // bolunmus SD CMD saati
  input  logic                      rst_n,

  // ---- L2-init / L3-block'tan komut istegi (seviye tabanli) ----------------
  input  logic                      req_valid_i,
  input  logic [5:0]                req_index_i,
  input  logic [31:0]               req_arg_i,
  input  ultra_sd_pkg::resp_e       req_resp_i,
  input  logic                      req_is_acmd_i,  // once CMD55 gonder
  output logic                      req_ready_o,

  // ---- sonuc (bir sonraki istek kabul edilene kadar seviye olarak durur) ---
  output logic                      rsp_valid_o,
  output logic [ultra_sd_pkg::RESP_LONG_BITS-1:0] rsp_data_o,     // saga dayali cerceve
  output logic                      rsp_crc_ok_o,
  output logic                      rsp_err_o,
  output ultra_sd_pkg::err_e        err_o,

  // ---- kart durumu ve sayaclar ---------------------------------------------
  input  logic [15:0]               rca_i,          // CMD55 argumani icin
  output logic                      card_ready_o,   // son R1'in READY_FOR_DATA
  output logic [15:0]               retry_cmd_o,    // STAT_RETRY[31:16]
  output logic [31:0]               stat_busy_o,    // Table 5-2 busy sayaci

  // ---- L0 (PHY) hat arayuzu ------------------------------------------------
  output logic                      cmd_out_o,      // negedge kanalindan
  output logic                      cmd_oe_o,       // 1 = host suruyor
  input  logic                      cmd_in_i        // posedge kanalinda okunur
);

  import ultra_sd_pkg::*;

  // ---------------------------------------------------------------------------
  // Cerceve geometrisi, Appendix A
  // ---------------------------------------------------------------------------
  // Komut: start(0) + dir(1) + index[5:0] + arg[31:0] + crc7 + stop(1)
  localparam int CMD_FRAME_BITS = 48;
  localparam int RESP_SHORT     = RESP_SHORT_BITS; // 48
  localparam int RESP_LONG      = RESP_LONG_BITS;  // 136, yalnizca R2

  // Her yanitin son 8 biti CRC7 + stop'tur: CRC alani bu kadar bit once biter.
  localparam int RESP_TAIL_BITS = 8;
  // R2'de CRC7 yalnizca CID/CSD'nin 120 bitini kapsar, yani cercevenin ilk
  // 8 biti (start + dir + 6 reserved) CRC'ye girmez.
  localparam int R2_CRC_SKIP    = 8;

  localparam int TX_CNT_W = $clog2(CMD_FRAME_BITS + 1);
  localparam int RX_CNT_W = $clog2(RESP_LONG + 1);
  localparam int TO_W     = $clog2(NCR_TIMEOUT_CLK + 1);
  localparam int GAP_W    = $clog2(NCC_GAP_CLK + 1);
  localparam int RTY_W    = $clog2(CMD_RETRIES + 1);

  // ---- R1 kart durumu, hata bitleri (Appendix A, card status) --------------
  localparam int R1_READY_FOR_DATA  = 8;   // hata degil, card_ready_o kaynagi
  localparam int R1_OUT_OF_RANGE    = 31;
  localparam int R1_ADDRESS_ERROR   = 30;
  localparam int R1_BLOCK_LEN_ERROR = 29;
  localparam int R1_ERASE_SEQ_ERROR = 28;
  localparam int R1_ERASE_PARAM     = 27;
  localparam int R1_WP_VIOLATION    = 26;
  localparam int R1_LOCK_UNLOCK_FAIL= 24;
  localparam int R1_COM_CRC_ERROR   = 23;
  localparam int R1_ILLEGAL_COMMAND = 22;
  localparam int R1_CARD_ECC_FAILED = 21;
  localparam int R1_CC_ERROR        = 20;
  localparam int R1_ERROR           = 19;
  localparam int R1_CSD_OVERWRITE   = 16;
  localparam int R1_AKE_SEQ_ERROR   = 3;

  localparam logic [31:0] R1_ERR_MASK =
      (32'd1 << R1_OUT_OF_RANGE)    | (32'd1 << R1_ADDRESS_ERROR)   |
      (32'd1 << R1_BLOCK_LEN_ERROR) | (32'd1 << R1_ERASE_SEQ_ERROR) |
      (32'd1 << R1_ERASE_PARAM)     | (32'd1 << R1_WP_VIOLATION)    |
      (32'd1 << R1_LOCK_UNLOCK_FAIL)| (32'd1 << R1_COM_CRC_ERROR)   |
      (32'd1 << R1_ILLEGAL_COMMAND) | (32'd1 << R1_CARD_ECC_FAILED) |
      (32'd1 << R1_CC_ERROR)        | (32'd1 << R1_ERROR)           |
      (32'd1 << R1_CSD_OVERWRITE)   | (32'd1 << R1_AKE_SEQ_ERROR);

  // 48-bit cercevede kart durumu [39:8] oturur: durum biti n = cerceve biti n+8.
  localparam int R1_STATUS_LSB = RESP_TAIL_BITS;

  // ---------------------------------------------------------------------------
  // Kontrol FSM'i (okuma kanalinda, posedge tarafinda durur)
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    C_IDLE,       // istek bekleniyor, hat bos
    C_LOAD,       // cerceve kuruldu, yazma kanaline veriliyor
    C_TX,         // yazma kanali 48 biti suruyor
    C_WAIT_RESP,  // NCR penceresi: yanitin start biti bekleniyor
    C_RX,         // yanit cercevesi kaydiriliyor
    C_EVAL,       // cerceve tamam: CRC7, stop biti ve kart durumu bakilir
    C_RETRY,      // tasima hatasi: ayni komut tekrar
    C_GAP,        // NCC: hat bos tutulur
    C_ERROR       // deneme hakki bitti
  } cmd_state_e;

  cmd_state_e           state_q;

  // NCC boslugunun sonunda nereye gidilecegi. Boslugu uc ayri yol kullanir
  // (CMD55 sonrasi asil komut, yeniden deneme, ve isin bitisi), bu yuzden
  // yon ayri bir kayitta durur -- C_GAP'in kendisi karar vermez.
  typedef enum logic [0:0] {
    GAP_TO_IDLE,  // is bitti: sonucu seviye olarak sur ve bosa dus
    GAP_TO_LOAD   // sirada bir cerceve daha var
  } gap_next_e;

  gap_next_e            gap_next_q;

  // Tasima hatasinin nedeni. err_o yalnizca deneme hakki bittiginde yazilir:
  // ucuncu denemede tutan bir komut hatasiz raporlanir.
  err_e                 fail_err_q;

  // ---- o anda hatta giden komutun beklenen yanit formati -------------------
  // Index / arg'in kendisi tutulmaz: tekrar gonderim de C_LOAD'a doner ve
  // cerceveyi ayni send55_q / req_* kaynagindan yeniden kurar.
  resp_e                cur_resp_q;
  // ---- isteklinin asil komutu (CMD55 arasina girdiginde saklanir) ----------
  logic [5:0]           req_index_q;
  logic [31:0]          req_arg_q;
  resp_e                req_resp_q;
  logic                 send55_q;      // simdi hatta giden CMD55 mi

  logic [RX_CNT_W-1:0]  resp_len_q;    // cur_resp_q'nun bit sayisi
  logic                 crc_chk_q;     // R3'te CRC alani anlamsiz: 1111111

  logic [TO_W-1:0]      to_cnt_q;
  logic [GAP_W-1:0]     gap_cnt_q;
  logic [RTY_W-1:0]     retry_q;
  logic [15:0]          retry_cmd_q;
  logic [31:0]          stat_busy_q;

  logic                 card_ready_q;
  logic                 rsp_valid_q;
  logic                 rsp_err_q;
  logic                 rsp_crc_ok_q;
  err_e                 err_q;

  // ---- kanallar arasi yarim-periyot el sikismasi ---------------------------
  logic                      tx_go_q;     // posedge -> negedge, seviye
  logic                      tx_done_q;   // negedge -> posedge, seviye

  // ---------------------------------------------------------------------------
  // CRC7: TEK toplayici, iki yon de bunu kullanir (ultra_sd_line'daki hat
  // basina tek toplayici mantiginin aynisi). Yazma ile okuma ASLA ayni anda
  // olmaz -- cerceve surulur, NCR beklenir, sonra yanit orneklenior -- bu
  // yuzden pahali olan tarafi, XOR agacini, iki kez ornekleme gerek yok.
  //
  // Onceki surum iki ornek tutuyordu: yazma icin IN_WIDTH=40 tek-atis XOR
  // agaci (40 girisli, 7 cikisli), okuma icin IN_WIDTH=1 toplayici. Simdi
  // yalnizca IN_WIDTH=1 olan var; yazma tarafi da kendi kalanini bit bit
  // birikterek bulur, cunku cerceve zaten bit bit hatta cikiyor. Boylece
  // 40-girisli agac ve onu besleyen 48-bit tx_frame_q sahne kaydi dusuyor.
  //
  // Besleme mux'u: o anda HAT UZERINDE olan bit. Yazarken dusen kenarda
  // surulen deger (bir sonraki yukselen kenarda kararli), okurken pedden
  // gelen deger. Yarim periyot yolu, CDC degil -- modul basligindaki
  // tx_go / tx_done el sikismasiyla ayni gerekce.
  // ---------------------------------------------------------------------------
  logic [5:0]                nxt_index;
  logic [31:0]               nxt_arg;
  logic [CMD_CRC7_BITS-1:0]  tx_crc_data;

  // CMD55 sirasi geldiyse hatta giden index/arg onun olmali.
  assign nxt_index   = send55_q ? CMD55_APP_CMD : req_index_q;
  assign nxt_arg     = send55_q ? {rca_i, 16'h0000} : req_arg_q;
  // start = 0, dir = 1 (host -> kart)
  assign tx_crc_data = {1'b0, 1'b1, nxt_index, nxt_arg};

  logic [CRC7_W-1:0] crc_q;      // paylasilan kalan
  logic [CRC7_W-1:0] crc_nxt;

  // Hattaki bit ve o bitin CRC'ye girip girmedigi. tx_crc_fold_q yazma
  // kanalinda uretilir: surulen bit cercevenin CRC kapsamindaki 40 bitinden
  // biriyse 1 olur.
  logic              crc_bit;
  logic              crc_fold_en;

  ultra_sd_crc7 #(
    .IN_WIDTH (1)
  ) u_crc7 (
    .crc_i  (crc_q),
    .data_i (crc_bit),
    .crc_o  (crc_nxt)
  );

  // CRC, R2'de ilk 8 biti atlar ve her yanitta son 8 biti (CRC7 + stop)
  // kapsam disinda birakir. rx_cnt_q = su an alinan bitin sirasi.
  logic [RX_CNT_W-1:0] rx_cnt_q;
  logic [RX_CNT_W-1:0] crc_skip;
  logic                rx_crc_en;

  assign crc_skip  = (cur_resp_q == RESP_R2) ? RX_CNT_W'(R2_CRC_SKIP)
                                             : RX_CNT_W'(0);
  assign rx_crc_en = (rx_cnt_q >= crc_skip) &&
                     (rx_cnt_q <  (resp_len_q - RX_CNT_W'(RESP_TAIL_BITS)));

  logic [RESP_LONG-1:0] resp_sh_q;

  // C_EVAL'de cerceve saga dayali olarak tamamdir: stop biti [0], CRC alani
  // [7:1]. Bu yuzden karar son bitin kaydirildigi kenarda DEGIL, bir sonraki
  // kenarda verilir -- aksi halde kiyaslama eksik kayit uzerinden yapilirdi.
  logic rx_last;
  logic frame_ok;
  assign rx_last  = (rx_cnt_q == (resp_len_q - RX_CNT_W'(1)));
  assign frame_ok = resp_sh_q[0] &&                       // stop biti 1
                    ((!crc_chk_q) || (crc_q == resp_sh_q[CRC7_W:1]));

  // ===========================================================================
  // YAZMA KANALI -- negedge cmd_clk
  //   Hatta giden her bit DUSEN kenarda degisir, kart YUKSELEN kenarda
  //   ornekler. Reset altinda ve cerceve bittiginde oe dusuk kalir: yaniti
  //   kart surecek, host hatti birakmak zorunda.
  // ===========================================================================
  // Cerceve uc segmentte surulur. Bolmenin tek nedeni CRC: kalan, kapsadigi
  // 40 bit hatta cikmadan once bilinemez, bu yuzden kaydirma kaydina
  // onceden gomulemez -- segment degisiminde dogrudan toplayicidan surulur.
  typedef enum logic [1:0] {
    TXS_HDR,   // start..arg, CRC kapsamindaki 40 bit
    TXS_CRC,   // toplayicinin kalani, 7 bit
    TXS_STOP   // stop biti
  } tx_seg_e;

  tx_seg_e                   tx_seg_q;
  logic [CMD_CRC7_BITS-1:0]  tx_sh_q;     // yalnizca header: 48 degil 40 bit
  logic [CRC7_W-1:0]         crc_sh_q;    // kalanin kaydirmasi
  logic [TX_CNT_W-1:0]       tx_cnt_q;    // segment icinde kalan bit
  logic                      tx_active_q;
  logic                      cmd_out_q;
  logic                      cmd_oe_q;
  logic                      tx_crc_fold_q; // hattaki bit CRC kapsaminda mi

  // Son bit: segmentin bu kenarda tukenmesi.
  logic tx_seg_last;
  assign tx_seg_last = (tx_cnt_q == TX_CNT_W'(1));

  always_ff @(negedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_seg_q      <= TXS_HDR;
      tx_sh_q       <= {CMD_CRC7_BITS{1'b1}};  // bos seviye
      crc_sh_q      <= '0;
      tx_cnt_q      <= '0;
      tx_active_q   <= 1'b0;
      tx_done_q     <= 1'b0;
      cmd_out_q     <= 1'b1;                   // oe erken acilsa bile hat bos
      cmd_oe_q      <= 1'b0;                   // yuksek empedans, pull-up kazanir
      tx_crc_fold_q <= 1'b0;
    end else if (tx_active_q) begin
      unique case (tx_seg_q)
        // Header: MSB'den surer, surulen her bit CRC'ye girer.
        TXS_HDR: begin
          cmd_out_q     <= tx_sh_q[CMD_CRC7_BITS-1];
          tx_sh_q       <= {tx_sh_q[CMD_CRC7_BITS-2:0], 1'b1};
          tx_crc_fold_q <= 1'b1;
          if (tx_seg_last) begin
            tx_seg_q <= TXS_CRC;
            tx_cnt_q <= TX_CNT_W'(CRC7_W);
          end else begin
            tx_cnt_q <= tx_cnt_q - TX_CNT_W'(1);
          end
        end

        // CRC: ilk bit dogrudan toplayicidan gelir. O an crc_q TAMDIR,
        // cunku header'in son biti aradaki yukselen kenarda katlandi.
        // Kalan alti bit yerel kaydirmadan cikar.
        TXS_CRC: begin
          if (tx_cnt_q == TX_CNT_W'(CRC7_W)) begin
            cmd_out_q <= crc_q[CRC7_W-1];
            crc_sh_q  <= {crc_q[CRC7_W-2:0], 1'b1};
          end else begin
            cmd_out_q <= crc_sh_q[CRC7_W-1];
            crc_sh_q  <= {crc_sh_q[CRC7_W-2:0], 1'b1};
          end
          tx_crc_fold_q <= 1'b0;   // CRC bitleri kendi kapsamina girmez
          if (tx_seg_last) begin
            tx_seg_q <= TXS_STOP;
            tx_cnt_q <= TX_CNT_W'(1);
          end else begin
            tx_cnt_q <= tx_cnt_q - TX_CNT_W'(1);
          end
        end

        // Stop biti: bu kenarda son bit surulur, hat birakilir.
        TXS_STOP: begin
          cmd_out_q     <= 1'b1;
          tx_crc_fold_q <= 1'b0;
          tx_active_q   <= 1'b0;
          tx_done_q     <= 1'b1;
          tx_cnt_q      <= '0;
        end

        default: tx_active_q <= 1'b0;
      endcase
    end else if (tx_go_q && !tx_done_q) begin
      // Kontrol FSM'i istegi kurdu: ilk bit bu dusen kenarda cikar. Sahne
      // kaydi yok -- header dogrudan tx_crc_data'dan yuklenir, cunku o
      // kombinasyonel deger send55_q / req_*_q uzerinden tum TX boyunca
      // kararlidir.
      cmd_oe_q      <= 1'b1;
      cmd_out_q     <= tx_crc_data[CMD_CRC7_BITS-1];
      tx_sh_q       <= {tx_crc_data[CMD_CRC7_BITS-2:0], 1'b1};
      tx_crc_fold_q <= 1'b1;
      tx_seg_q      <= TXS_HDR;
      tx_cnt_q      <= TX_CNT_W'(CMD_CRC7_BITS - 1);
      tx_active_q   <= 1'b1;
    end else begin
      // Bos: hat birakilmis, el sikismasi kontrol tarafindan temizlenir.
      cmd_oe_q      <= 1'b0;
      cmd_out_q     <= 1'b1;
      tx_crc_fold_q <= 1'b0;
      if (!tx_go_q) begin
        tx_done_q <= 1'b0;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Paylasilan toplayicinin beslemesi. Yazarken hattaki bit cmd_out_q,
  // okurken cmd_in_i. Katlama yalnizca kapsam icindeki bitlerde.
  // ---------------------------------------------------------------------------
  assign crc_bit     = tx_crc_fold_q ? cmd_out_q : cmd_in_i;
  // C_WAIT_RESP'te katlama YALNIZCA start biti hatta dustugunde acilir: NCR
  // penceresi boyunca hat bos (1) durur ve o bosta gecen bitleri katlamak
  // kisa yanitlarda (crc_skip = 0) toplayiciyi bozar. R2'de crc_skip = 8
  // oldugu icin bu hata orada gorunmez.
  assign crc_fold_en = tx_crc_fold_q ||
                       (((state_q == C_WAIT_RESP && !cmd_in_i) ||
                         (state_q == C_RX)) && rx_crc_en);

  // ===========================================================================
  // OKUMA / KONTROL KANALI -- posedge cmd_clk
  //   Kartin surdugu bit YUKSELEN kenarda yakalanir. Komut siralamasi,
  //   NCR / NCC pencereleri ve yeniden deneme politikasi da burada durur.
  // ===========================================================================
  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      // ---- FAZ 0 reset degerleri --------------------------------------------
      state_q      <= C_IDLE;       // hicbir komut acik degil
      gap_next_q   <= GAP_TO_IDLE;
      fail_err_q   <= ERR_OK;
      cur_resp_q   <= RESP_NONE;
      req_index_q  <= '0;
      req_arg_q    <= '0;
      req_resp_q   <= RESP_NONE;
      send55_q     <= 1'b0;
      resp_len_q   <= RX_CNT_W'(RESP_SHORT);
      crc_chk_q    <= 1'b1;
      to_cnt_q     <= '0;           // timeout sayaci duruk
      gap_cnt_q    <= '0;
      retry_q      <= '0;
      retry_cmd_q  <= '0;           // STAT_RETRY temiz (Table 5-2)
      stat_busy_q  <= '0;
      card_ready_q <= 1'b0;         // STATUS.CARD_READY = 0
      rsp_valid_q  <= 1'b0;
      rsp_err_q    <= 1'b0;
      rsp_crc_ok_q <= 1'b0;
      err_q        <= ERR_OK;       // REG_ERR reset degeri
      rx_cnt_q     <= '0;
      crc_q        <= CRC7_INIT;
      resp_sh_q    <= '0;
      tx_go_q      <= 1'b0;         // yazma kanaline istek yok
    end else begin
      // Table 5-2: CMD kanalinin mesgul gectirdigi SD saat cevrimleri.
      if (state_q != C_IDLE) begin
        stat_busy_q <= stat_busy_q + 32'd1;
      end

      // ---- paylasilan CRC7: hattaki biti katla ------------------------------
      // TEK nokta. Yazma ve okuma ayni toplayiciyi kullandigi icin katlama da
      // tek yerde durur; asagidaki case yalnizca toplayiciyi SIFIRLAR
      // (segment basi), hiclbir yerde ikinci bir katlama yoktur.
      if (crc_fold_en) begin
        crc_q <= crc_nxt;
      end

      unique case (state_q)
        // ---------------------------------------------------------------------
        C_IDLE: begin
          if (req_valid_i) begin
            req_index_q  <= req_index_i;
            req_arg_q    <= req_arg_i;
            req_resp_q   <= req_resp_i;
            send55_q     <= req_is_acmd_i;   // ACMD once CMD55 ister
            retry_q      <= '0;
            rsp_valid_q  <= 1'b0;            // onceki sonuc gecersiz
            rsp_err_q    <= 1'b0;
            rsp_crc_ok_q <= 1'b0;
            err_q        <= ERR_OK;
            fail_err_q   <= ERR_OK;
            state_q      <= C_LOAD;
          end
        end

        // ---------------------------------------------------------------------
        // Cerceveyi kur: CRC7 kombinasyonel agactan gelir, stop biti 1.
        // Yeniden deneme de buraya doner ve ayni cerceveyi yeniden uretir.
        C_LOAD: begin
          cur_resp_q  <= send55_q ? RESP_R1 : req_resp_q;
          resp_len_q  <= (!send55_q && (req_resp_q == RESP_R2))
                           ? RX_CNT_W'(RESP_LONG) : RX_CNT_W'(RESP_SHORT);
          // R3 (OCR) CRC alanini 1111111 ile doldurur: dogrulanamaz.
          crc_chk_q   <= send55_q ? 1'b1 : (req_resp_q != RESP_R3);
          // Yazma kanali header'i kendisi yukler; burada yalnizca paylasilan
          // toplayici sifirlanir. Bir sonraki dusen kenarda ilk bit cikar,
          // onu takip eden yukselen kenarda katlanmaya baslar.
          crc_q       <= CRC7_INIT;
          tx_go_q     <= 1'b1;
          state_q     <= C_TX;
        end

        // ---------------------------------------------------------------------
        C_TX: begin
          if (tx_done_q) begin
            tx_go_q   <= 1'b0;               // el sikismasini birak
            gap_cnt_q <= GAP_W'(NCC_GAP_CLK);
            if (cur_resp_q == RESP_NONE) begin
              // CMD0 gibi yanitsiz komut: dogrudan NCC boslugu.
              gap_next_q <= GAP_TO_IDLE;
              state_q    <= C_GAP;
            end else begin
              to_cnt_q  <= TO_W'(NCR_TIMEOUT_CLK);
              rx_cnt_q  <= '0;
              crc_q     <= CRC7_INIT;   // ayni toplayici, simdi okuma icin
              resp_sh_q <= '0;
              state_q   <= C_WAIT_RESP;
            end
          end
        end

        // ---------------------------------------------------------------------
        // NCR penceresi. Hat pull-up ile yukarida; ilk gorulen 0 yanitin
        // start bitidir ve cerceveye dahildir.
        C_WAIT_RESP: begin
          if (!cmd_in_i) begin
            resp_sh_q <= {resp_sh_q[RESP_LONG-2:0], cmd_in_i};
            rx_cnt_q  <= RX_CNT_W'(1);
            state_q   <= C_RX;
          end else if (to_cnt_q == '0) begin
            fail_err_q <= ERR_CMD_TIMEOUT;   // Table 5-3
            state_q    <= C_RETRY;
          end else begin
            to_cnt_q <= to_cnt_q - TO_W'(1);
          end
        end

        // ---------------------------------------------------------------------
        C_RX: begin
          resp_sh_q <= {resp_sh_q[RESP_LONG-2:0], cmd_in_i};
          if (rx_last) begin
            rx_cnt_q <= '0;
            state_q  <= C_EVAL;
          end else begin
            rx_cnt_q <= rx_cnt_q + RX_CNT_W'(1);
          end
        end

        // ---------------------------------------------------------------------
        // Cerceve tamam: stop biti ve CRC7 burada bakilir.
        C_EVAL: begin
          gap_cnt_q <= GAP_W'(NCC_GAP_CLK);
          if (!frame_ok) begin
            fail_err_q <= ERR_CMD_CRC;       // Table 5-3
            state_q    <= C_RETRY;
          end else if (send55_q) begin
            // CMD55 kabul edildi: NCC boslugundan sonra sira asil ACMD'de.
            send55_q   <= 1'b0;
            retry_q    <= '0;
            gap_next_q <= GAP_TO_LOAD;
            state_q    <= C_GAP;
          end else begin
            rsp_crc_ok_q <= 1'b1;
            // R1 / R1b kart durumu: READY_FOR_DATA ve hata bitleri.
            if ((cur_resp_q == RESP_R1) || (cur_resp_q == RESP_R1B)) begin
              card_ready_q <= resp_sh_q[R1_STATUS_LSB + R1_READY_FOR_DATA];
              if ((resp_sh_q[R1_STATUS_LSB +: 32] & R1_ERR_MASK) != 32'h0) begin
                // Tasima degil, kartin kendi hatasi: tekrar denemek anlamsiz,
                // cerceve gecerli oldugu icin veri yine yukari verilir.
                err_q     <= ERR_CMD_STATUS;
                rsp_err_q <= 1'b1;
              end
            end
            gap_next_q <= GAP_TO_IDLE;
            state_q    <= C_GAP;
          end
        end

        // ---------------------------------------------------------------------
        // Tasima hatasi: ayni komut, CMD_RETRIES kez. Her tekrar STAT_RETRY'ye
        // islenir (Table 5-2).
        C_RETRY: begin
          gap_cnt_q <= GAP_W'(NCC_GAP_CLK);
          if (retry_q < RTY_W'(CMD_RETRIES)) begin
            retry_q     <= retry_q + RTY_W'(1);
            retry_cmd_q <= retry_cmd_q + 16'd1;
            gap_next_q  <= GAP_TO_LOAD;
            state_q     <= C_GAP;
          end else begin
            state_q <= C_ERROR;
          end
        end

        // ---------------------------------------------------------------------
        // NCC: iki cerceve arasinda hat en az NCC_GAP_CLK cevrim bos kalir.
        C_GAP: begin
          if (gap_cnt_q != '0) begin
            gap_cnt_q <= gap_cnt_q - GAP_W'(1);
          end else if (gap_next_q == GAP_TO_LOAD) begin
            state_q <= C_LOAD;
          end else begin
            rsp_valid_q <= 1'b1;             // seviye: yeni istege kadar durur
            state_q     <= C_IDLE;
          end
        end

        // ---------------------------------------------------------------------
        C_ERROR: begin
          err_q       <= fail_err_q;         // timeout ya da CRC
          rsp_err_q   <= 1'b1;
          rsp_valid_q <= 1'b1;
          state_q     <= C_IDLE;
        end

        default: state_q <= C_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Ciktilar. Hepsi flop cikisi: pedlere ve karsi katmana giden yolda
  // kombinasyonel mantik yoktur.
  // ---------------------------------------------------------------------------
  assign req_ready_o  = (state_q == C_IDLE);
  assign rsp_valid_o  = rsp_valid_q;
  assign rsp_data_o   = resp_sh_q;
  assign rsp_crc_ok_o = rsp_crc_ok_q;
  assign rsp_err_o    = rsp_err_q;
  assign err_o        = err_q;

  assign card_ready_o = card_ready_q;
  assign retry_cmd_o  = retry_cmd_q;
  assign stat_busy_o  = stat_busy_q;

  assign cmd_out_o    = cmd_out_q;
  assign cmd_oe_o     = cmd_oe_q;

endmodule

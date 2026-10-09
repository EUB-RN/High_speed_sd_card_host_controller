// -----------------------------------------------------------------------------
// ultra_sd_cmd
//   Purpose      : L2'nin TAMAMI. Iki FSM bir modulde:
//                    - komut motoru (C_*): CMD cercevesi, CRC7, yanit cozme
//                    - baslatma merdiveni (I_*): CMD0..CMD6 sirasi
//
//   Neden tek modul: ikisi ayriyken istekleri ultra_sd_top'ta birlestiriliyordu
//   ve bu, arg yolunda IKI ayri 32-bit secim katmani demekti --
//   (1) merdivenin kendi sabit decode'u (step_cnt -> 32-bit arg)
//   (2) top'taki 42-bitlik 2:1 arbitrasyon mux'u (init_busy ? init : blok)
//   ustune hazir/yanit yonlendirmesi icin bir avuc kapi daha. Ikisi tek modulde
//   oldugu icin artik TEK katman var: merdivenin sabitleri dogrudan paylasilan
//   req_*_q registerina yaziliyor, arada mux yok. Ayrica su portlar komple
//   ortadan kalkti: merdivenin req_valid/index/arg/resp/is_acmd cikislari,
//   rca geri besleme dongusu ve cmd_err geri yolu.
//
//   Neden guvenli: iki istekci ASLA ayni anda var olamaz. Blok katmaninin
//   istegi xfer_go'ya bagli, xfer_go init_done'dan sonra gelir, yani merdiven
//   koserken blok hic istek acmaz. O yuzden burada bir arbiter de, yanitin
//   kime gidecegini hatirlayan bir flop da yok -- cevap init_owns'in
//   kendisinde yazili.
//
//   Clock domain : cmd_clk (PHY'de gate'lenmis, bolunmus SD saati)
// -----------------------------------------------------------------------------

module ultra_sd_cmd
  import ultra_sd_pkg::*;
#(
  // ---- komut motoru ----
  parameter int NCR_TIMEOUT_CLK = 64,
  parameter int NCC_GAP_CLK     = 8,
  parameter int CMD_RETRIES     = 3,

  // ---- baslatma merdiveni ----
  parameter int CLK_DIV_INIT       = 250,
  parameter int CLK_DIV_DS         = 4,
  parameter int CLK_DIV_HS         = 2,
  parameter int ACMD41_TIMEOUT_CLK = 400_000,
  parameter int DAT_TIMEOUT_CLK    = 200_000,
  parameter logic [31:0] OCR_REQUEST = 32'h40FF_8000,
  parameter bit SCR_CHECK          = 1'b1,
  parameter bit HS_ENABLE          = 1'b1
) (
  input  logic                      cmd_clk,
  input  logic                      rst_n,

  // ---- L3 (blok katmani) istek portu --------------------------------------
  // Merdiven koserken req_ready_o alcaktir: hat merdivenin.
  input  logic                      req_valid_i,
  input  logic [5:0]                req_index_i,
  input  logic [31:0]               req_arg_i,
  input  resp_e                     req_resp_i,
  input  logic                      req_is_acmd_i,
  output logic                      req_ready_o,

  output logic                      rsp_valid_o,
  output logic [RESP_LONG_BITS-1:0] rsp_data_o,
  output logic                      rsp_crc_ok_o,
  output logic                      rsp_err_o,
  output err_e                      err_o,

  output logic                      card_ready_o,

  // ---- baslatma merdiveni: tetik ve sonuclar ------------------------------
  input  logic                      card_present_i,
  input  logic                      ramp_done_i,

  // ---- Table 7-1 geri cekilme bitleri (CFG_PHY) ----------------------------
  // Ikisi de MERDIVENIN karar anlarinda tuketiliyor, L1'in girisinde degil.
  // Sebebi: genislik ve hiz kartla ANLASMADIR. Host tarafini tek basina
  // daraltmak karti 4-bit'te birakip hatti 1-bit okumak demekti; bu yuzden
  // force_1bit ACMD6'nin ARGUMANINI degistiriyor, yani kart da 1-bit'e
  // geciyor ve bus_4bit_o her zaman gercek genisligi soyluyor (R-DEG-5).
  // force_ds ise CMD6 switch'ini hic yapmiyor: hiz Default Speed'de,
  // clk_div CLK_DIV_DS'te kaliyor.
  // Ikisi de merdiven kosarken ornekleniyor, yani yazilim once CFG_PHY'yi
  // yazar sonra CTRL.SOFT_RESET verir (register dosyasi sys_rst_n ile kurulu,
  // soft reset CFG_PHY'yi silmez) -- Section 7.4 "ayni bitstream, yalnizca
  // konfigurasyon degisikligi" prosedurunun tam karsiligi.
  input  logic                      force_1bit_i,
  input  logic                      force_ds_i,
  output logic                      init_busy_o,
  output logic                      init_done_o,
  output logic                      init_err_o,
  output err_e                      init_err_code_o,

`ifdef ULTRA_SD_DEBUG_PORT
  // ---- gozlem portu: YALNIZCA ULTRA_SD_DEBUG_PORT tanimliyken var ---------
  // Makro tanimli degilken bu port yoktur ve Section 5.2'nin port listesi
  // oldugu gibi kalir. Kart ERR_INIT ile duruyorsa merdivenin NEREDE durdugu
  // disaridan gorulemez: init_err_code tek bir kod, ve ACMD41 adiminda
  // "kart hala mesgul" ile "CMD55 hic cevap vermedi" ayni kodu uretir.
  // Alanlar yavas degisir ve yalnizca gozlem icindir; hicbir kontrol yolu
  // buna bagli degil.
  output logic [63:0]               dbg_o,
`endif

  // Merdivenin DAT okumalari (ACMD51 SCR, CMD6 switch status)
  output logic                      dat_rd_start_o,
  output logic [10:0]               dat_rd_bytes_o,
  // Merdiven yalnizca SCR'nin ve switch-status'un tek bir byte'ini okur.
  /* verilator lint_off UNUSED */
  input  logic [31:0]               dat_rd_data_i,
  /* verilator lint_on UNUSED */
  input  logic                      dat_rd_valid_i,
  input  logic                      dat_rd_busy_i,
  input  logic                      dat_rd_crc_ok_i,

  // Merdivenin ogrendigi kart durumu
  output logic [15:0]               rca_o,
  output logic [31:0]               card_blk_o,
  output logic                      block_addr_o,
  output speed_e                    speed_o,
  output logic                      bus_4bit_o,
  output logic [CFG_CLK_W-1:0]      clk_div_o,

  // ---- Table 5-2: STAT_RETRY'nin komut yarisi ------------------------------
  // Olay C_RETRY kolunun ta kendisi, o yuzden ham darbeyi disari verip baska
  // bir modulde saymak yerine burada sayiyoruz -- darbe bu saatte zaten tam
  // bir cevrim, kenar yakalamaya da gerek yok. Silme toggle gelir (cdc.md 9).
  input  logic                      stat_clear_tgl_i,
  output logic [15:0]               stat_retry_cmd_o,

  // ---- CMD pedi ------------------------------------------------------------
  output logic                      cmd_out_o,
  output logic                      cmd_oe_o,
  input  logic                      cmd_in_i
);


  // ===========================================================================
  // L2b -- baslatma merdiveni (I_*). Komut motoruyla ayni saatte ve ayni
  // modulde; istegini yukaridaki paylasilan yukleme katmanina veriyor.
  // ===========================================================================
  // Merdivenin TEK durumu: hayat dongusu. Eskiden burada 6 durumlu ayri bir
  // FSM vardi (I_IDLE/I_SEND/I_RESP/I_DAT/I_DONE/I_ERROR) ve sirlayicinin
  // zaten yaptigi "istek bas -> hazir bekle -> yanit bekle" isini IKINCI kez
  // kuruyordu; ustune iki FSM'i baglamak icin init_req_valid/init_req_ready/
  // init_rsp_valid/init_rsp_err koprusu gerekiyordu. Hepsi gitti: merdiven
  // artik bir SAYAC (step_cnt) + sabit komut ROM'u + kendi cevap tablosu.
  // Gonderici komutu ondan CEKIYOR, siralama tek yerde.
  typedef enum logic [1:0] {
    INIT_IDLE,   // rampa bekleniyor
    INIT_RUN,    // merdiven kosuyor, hat merdivenin
    INIT_DONE,
    INIT_ERR
  } init_mode_e;

  init_mode_e  init_mode_q;
  logic        init_owns;
  logic        cmd_idle;

  // ---------------------------------------------------------------------------
  // clk alanindan gelen tek-bit kontrollerin senkronizeri (cdc.md 6, 8)
  //
  // Dordu de system_controller'in / register dosyasinin saatinde uretiliyor ve
  // burada SD saatinde tuketiliyor. Eskiden HICBIRI senkronize edilmiyordu --
  // cdc.md satir 8 "iki flop senkronizer" diyordu ama o senkronizer yalnizca
  // ultra_sd_block'ta vardi, burada yoktu.
  //
  // Bedeli yalnizca metastabilite degildi, ZAMANLAMA idi: card_present dogrudan
  // kart-cikarma temizligini suruyor (rca, card_blk, step_cnt, speed, clk_div,
  // init_err_code + bir avuc CE), yani genis bir fanout konisinin tepesinde
  // kombinasyonel duruyordu. STA bunu sys_clk -> sd_clk_core gecisi olarak,
  // YARIM periyotluk (10.101 ns) pencereyle olcuyor ve en kotu yol -0.867 ns
  // ile dusuyordu. Senkronizerden sonra ayni koninin tepesinde bu saatte duran
  // bir flop var: koni degismedi, ama pencere TAM periyoda (20.202 ns) cikti.
  // ---------------------------------------------------------------------------
  logic [1:0] pres_sync_q, ramp_sync_q, f1b_sync_q, fds_sync_q;

  logic card_present, ramp_done, force_1bit, force_ds;
  assign card_present = pres_sync_q[1];
  assign ramp_done    = ramp_sync_q[1];
  assign force_1bit   = f1b_sync_q[1];
  assign force_ds     = fds_sync_q[1];

  logic [RESP_LONG_BITS-1:0] rsp_data;

  logic        ld_valid;
  logic [5:0]  ld_index;
  logic [31:0] ld_arg;
  resp_e       ld_resp;
  logic        ld_acmd;

  localparam int CMD_FRAME_BITS = 48;
  localparam int RESP_SHORT     = RESP_SHORT_BITS;
  localparam int RESP_LONG      = RESP_LONG_BITS;

  localparam int RESP_TAIL_BITS = 8;

  localparam int R2_CRC_SKIP    = 8;

  localparam  TX_CNT_W  = $clog2(CMD_FRAME_BITS + 1);
  localparam  RX_CNT_W  = $clog2(RESP_LONG + 1);
  localparam  TIMER_MAX = (NCR_TIMEOUT_CLK > NCC_GAP_CLK) ? NCR_TIMEOUT_CLK : NCC_GAP_CLK;
  localparam  TIMER_W   = $clog2(TIMER_MAX + 1);
  localparam  RTY_W     = $clog2(CMD_RETRIES + 1);

  localparam  R1_READY_FOR_DATA  = 8;
  localparam  R1_OUT_OF_RANGE    = 31;
  localparam  R1_ADDRESS_ERROR   = 30;
  localparam  R1_BLOCK_LEN_ERROR = 29;
  localparam  R1_ERASE_SEQ_ERROR = 28;
  localparam  R1_ERASE_PARAM     = 27;
  localparam  R1_WP_VIOLATION    = 26;
  localparam  R1_LOCK_UNLOCK_FAIL= 24;
  localparam  R1_COM_CRC_ERROR   = 23;
  localparam  R1_ILLEGAL_COMMAND = 22;
  localparam  R1_CARD_ECC_FAILED = 21;
  localparam  R1_CC_ERROR        = 20;
  localparam  R1_ERROR           = 19;
  localparam  R1_CSD_OVERWRITE   = 16;
  localparam  R1_AKE_SEQ_ERROR   = 3;

  localparam  [31:0] R1_ERR_MASK =
      (32'd1 << R1_OUT_OF_RANGE)    | (32'd1 << R1_ADDRESS_ERROR)   |
      (32'd1 << R1_BLOCK_LEN_ERROR) | (32'd1 << R1_ERASE_SEQ_ERROR) |
      (32'd1 << R1_ERASE_PARAM)     | (32'd1 << R1_WP_VIOLATION)    |
      (32'd1 << R1_LOCK_UNLOCK_FAIL)| (32'd1 << R1_COM_CRC_ERROR)   |
      (32'd1 << R1_ILLEGAL_COMMAND) | (32'd1 << R1_CARD_ECC_FAILED) |
      (32'd1 << R1_CC_ERROR)        | (32'd1 << R1_ERROR)           |
      (32'd1 << R1_CSD_OVERWRITE)   | (32'd1 << R1_AKE_SEQ_ERROR);

  localparam int R1_STATUS_LSB = RESP_TAIL_BITS;

  typedef enum logic [3:0] {
    C_IDLE,
    C_LOAD,
    C_TX,
    C_WAIT_RESP,
    C_RX,
    C_EVAL,
    C_RETRY,
    C_GAP,
    C_DAT,      // merdivenin DAT yuku (ACMD51 SCR, CMD6 switch status)
    C_FIN,      // komut bitti: TEK cevap dagitim noktasi
    C_ERROR
  } cmd_state_e;

  cmd_state_e           state_q;

  typedef enum logic [0:0] {
    GAP_TO_IDLE,
    GAP_TO_LOAD
  } gap_next_e;

  gap_next_e            gap_next_q;

  logic                 fail_is_crc_q;

  resp_e                cur_resp_q;

  // Istek KOPYASI YOK. Eskiden burada req_index_q / req_arg_q / req_resp_q
  // duruyordu (40 flop) ve uretici -> bu register -> gonderici seklinde fazladan
  // bir kademe yapiyordu. Gonderici artik ureticinin cikisini DOGRUDAN okuyor:
  // ikisi de komut boyunca sabit (init'te step_cnt, blokta step_q ilerlemiyor).
  // Kalan tek durum biti komutun SAHIBI: komut suresince donar, boylece kart
  // cikarma gibi bir olay ortasinda uretici degistirip cerceveyi bozamaz.
  logic                 init_owns_q;
  logic                 send55_q;

  logic                 is_long_resp_q;
  logic                 crc_chk_q;
  logic                 r1_chk_q;

  logic [TIMER_W-1:0]   timer_cnt_q;
  logic [RTY_W-1:0]     retry_q;

  // Silme komutunun senkronizeri (cdc.md 9). retry_q blok basina sifirlanan
  // deneme sayaci, stat_rty_cmd_q ise omur boyu toplam.
  logic [STAT_RTY_W-1:0] stat_rty_cmd_q;
  logic [1:0]            clr_sync_q;
  logic                  clr_q;
  logic                  stat_clear;

  assign stat_clear = clr_sync_q[1] ^ clr_q;

  logic                 card_ready_q;
  logic                 rsp_valid_q;
  logic                 rsp_err_q;
  logic                 rsp_crc_ok_q;
  err_e                 err_q;

  logic                      tx_go_q;
  logic                      tx_done_q;

  // ===========================================================================
  // GONDERICI (tek ornek, iki uretici paylasir)
  //
  // 48 bitlik komut cercevesini CMD'ye seri verir ve CRC7'sini uretir. Hangi
  // ureticinin komutunu gonderdigini bilmez: onune konan index/arg'i gonderir.
  // ACMD'de ayni gonderici once CMD55'i, sonra komutun kendisini gonderir --
  // tek fark asagidaki send55_q override'i.
  // ===========================================================================
  logic [5:0]                nxt_index;
  logic [31:0]               nxt_arg;
  logic [CMD_CRC7_BITS-1:0]  tx_crc_data;

  assign nxt_index   = send55_q ? CMD55_APP_CMD    : ld_index;
  assign nxt_arg     = send55_q ? {rca_q, 16'h0000} : ld_arg;

  assign tx_crc_data = {1'b0, 1'b1, nxt_index, nxt_arg};

  logic [CRC7_W-1:0] crc_q;
  logic [CRC7_W-1:0] crc_nxt;

  logic              crc_bit;
  logic              crc_fold_en;

  ultra_sd_crc7 #(
    .IN_WIDTH (1)
  ) u_crc7 (
    .crc_i  (crc_q),
    .data_i (crc_bit),
    .crc_o  (crc_nxt)
  );

  logic [RX_CNT_W-1:0] rx_cnt_q;
  logic [RX_CNT_W-1:0] crc_skip;
  logic                rx_crc_en;

  assign crc_skip  = (cur_resp_q == RESP_R2) ? RX_CNT_W'(R2_CRC_SKIP)
                                             : RX_CNT_W'(0);
  assign rx_crc_en = (rx_cnt_q >= crc_skip) && (!rx_last);

  localparam int RESP_SHORT_DATA = 40;
  logic [RESP_SHORT_DATA-1:0] resp_sh_q;
  logic [1:0]                 csd_struct_q;
  logic [36:0]                csd_payload_q;
  logic                       stop_bit_q;

  logic rx_last;
  logic frame_ok;
  assign rx_last  = is_long_resp_q ? (rx_cnt_q == RX_CNT_W'(RESP_LONG - 1))
                                   : (rx_cnt_q == RX_CNT_W'(RESP_SHORT - 1));
  assign frame_ok = (cur_resp_q == RESP_R2 ? stop_bit_q : resp_sh_q[0]) &&
                    ((!crc_chk_q) || (crc_q == CRC7_W'(0)));

  // ===========================================================================
  // OKUYUCU (tek ornek, iki tuketici paylasir)
  //
  // Yanit cercevesini CMD'den toplar: kisa yanitlar resp_sh_q'ya, R2'nin
  // ilgilenilen alanlari (CSD_STRUCTURE ve C_SIZE penceresi) kendi
  // registerlarina. Cercevenin gecerliligi (stop biti + CRC7) frame_ok'ta.
  // Yanitin NE ANLAMA geldigini yorumlamaz -- onu iki ayri cevap isleyici
  // yapar: merdivenin kendi tablosu ve sistem yolunun R1 isleyicisi.
  // ===========================================================================
  logic rx_shift_en;
  assign rx_shift_en = ((state_q == C_WAIT_RESP) && !cmd_in_i) ||
                       (state_q == C_RX);

  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      resp_sh_q     <= '0;
      csd_struct_q  <= '0;
      csd_payload_q <= '0;
      stop_bit_q    <= 1'b0;
      rx_cnt_q      <= '0;
    end else if (rx_shift_en) begin
      if (cur_resp_q != RESP_R2) begin
        resp_sh_q <= {resp_sh_q[RESP_SHORT_DATA-2:0], cmd_in_i};
      end else begin
        if ((rx_cnt_q == RX_CNT_W'(8)) || (rx_cnt_q == RX_CNT_W'(9))) begin
          csd_struct_q <= {csd_struct_q[0], cmd_in_i};
        end else if ((rx_cnt_q >= RX_CNT_W'(52)) &&
                     (rx_cnt_q <= RX_CNT_W'(88))) begin
          csd_payload_q <= {csd_payload_q[35:0], cmd_in_i};
        end
      end

      if (state_q == C_WAIT_RESP) begin
        rx_cnt_q <= RX_CNT_W'(1);      // baslangic biti sayildi
      end else if (rx_last) begin
        stop_bit_q <= cmd_in_i;
        rx_cnt_q   <= '0;
      end else begin
        rx_cnt_q <= rx_cnt_q + RX_CNT_W'(1);
      end
    end else if (state_q == C_TX) begin
      rx_cnt_q <= '0;
    end
  end

  logic r1_has_err;
  assign r1_has_err = resp_sh_q[R1_STATUS_LSB + 31] |
                      resp_sh_q[R1_STATUS_LSB + 30] |
                      resp_sh_q[R1_STATUS_LSB + 29] |
                      resp_sh_q[R1_STATUS_LSB + 28] |
                      resp_sh_q[R1_STATUS_LSB + 27] |
                      resp_sh_q[R1_STATUS_LSB + 26] |
                      resp_sh_q[R1_STATUS_LSB + 24] |
                      resp_sh_q[R1_STATUS_LSB + 23] |
                      resp_sh_q[R1_STATUS_LSB + 22] |
                      resp_sh_q[R1_STATUS_LSB + 21] |
                      resp_sh_q[R1_STATUS_LSB + 20] |
                      resp_sh_q[R1_STATUS_LSB + 19] |
                      resp_sh_q[R1_STATUS_LSB + 16] |
                      resp_sh_q[R1_STATUS_LSB + 3];

  logic [CMD_CRC7_BITS-1:0]  tx_sh_q;
  logic [TX_CNT_W-1:0]       tx_cnt_q;
  logic                      tx_active_q;
  logic                      cmd_out_q;
  logic                      cmd_oe_q;
  logic                      tx_crc_fold_q;

  always_ff @(negedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_sh_q       <= {CMD_CRC7_BITS{1'b1}};
      tx_cnt_q      <= '0;
      tx_active_q   <= 1'b0;
      tx_done_q     <= 1'b0;
      cmd_out_q     <= 1'b1;
      cmd_oe_q      <= 1'b0;
      tx_crc_fold_q <= 1'b0;
    end else if (tx_active_q) begin
      tx_cnt_q <= tx_cnt_q - TX_CNT_W'(1);
      if (tx_cnt_q > TX_CNT_W'(8)) begin
        cmd_out_q     <= tx_sh_q[CMD_CRC7_BITS-1];
        tx_sh_q       <= {tx_sh_q[CMD_CRC7_BITS-2:0], 1'b1};
        tx_crc_fold_q <= 1'b1;
      end else if (tx_cnt_q == TX_CNT_W'(8)) begin

        cmd_out_q           <= crc_q[CRC7_W-1];
        tx_sh_q[CRC7_W-2:0] <= crc_q[CRC7_W-2:0];
        tx_crc_fold_q       <= 1'b0;
      end else if (tx_cnt_q > TX_CNT_W'(1)) begin

        cmd_out_q           <= tx_sh_q[CRC7_W-2];
        tx_sh_q[CRC7_W-2:0] <= {tx_sh_q[CRC7_W-3:0], 1'b1};
        tx_crc_fold_q       <= 1'b0;
      end else begin

        cmd_out_q     <= 1'b1;
        tx_crc_fold_q <= 1'b0;
        tx_active_q   <= 1'b0;
        tx_done_q     <= 1'b1;
      end
    end else if (tx_go_q && !tx_done_q) begin
      cmd_oe_q      <= 1'b1;
      cmd_out_q     <= tx_crc_data[CMD_CRC7_BITS-1];
      tx_sh_q       <= {tx_crc_data[CMD_CRC7_BITS-2:0], 1'b1};
      tx_crc_fold_q <= 1'b1;
      tx_cnt_q      <= TX_CNT_W'(CMD_FRAME_BITS - 1);
      tx_active_q   <= 1'b1;
    end else begin
      cmd_oe_q      <= 1'b0;
      cmd_out_q     <= 1'b1;
      tx_crc_fold_q <= 1'b0;
      if (!tx_go_q) begin
        tx_done_q <= 1'b0;
      end
    end
  end

  assign crc_bit     = tx_crc_fold_q ? cmd_out_q : cmd_in_i;

  assign crc_fold_en = tx_crc_fold_q ||
                       (((state_q == C_WAIT_RESP && !cmd_in_i) ||
                         (state_q == C_RX)) && rx_crc_en);

  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin

      state_q        <= C_IDLE;
      gap_next_q     <= GAP_TO_IDLE;
      fail_is_crc_q  <= 1'b0;
      cur_resp_q     <= RESP_NONE;
      init_owns_q    <= 1'b0;
      init_mode_q    <= INIT_IDLE;
      step_cnt       <= 4'd0;
      rca_q          <= '0;
      card_blk_q     <= '0;
      block_addr_q   <= 1'b0;
      speed_q        <= SPEED_INIT;
      bus_4bit_q     <= 1'b0;
      clk_div_q      <= CFG_CLK_W'(CLK_DIV_INIT);
      init_err_code_q<= ERR_OK;
      wait_cnt_q     <= '0;
      word_cnt_q     <= '0;
      dat_cap_q      <= '0;
      scr_4bit_q     <= 1'b0;
      send55_q       <= 1'b0;
      is_long_resp_q <= 1'b0;
      crc_chk_q      <= 1'b1;
      r1_chk_q       <= 1'b0;
      timer_cnt_q    <= '0;
      retry_q        <= '0;
      stat_rty_cmd_q <= '0;
      clr_sync_q     <= 2'b00;
      clr_q          <= 1'b0;
      pres_sync_q    <= 2'b00;
      ramp_sync_q    <= 2'b00;
      f1b_sync_q     <= 2'b00;
      fds_sync_q     <= 2'b00;
      card_ready_q   <= 1'b0;
      rsp_valid_q    <= 1'b0;
      rsp_err_q      <= 1'b0;
      rsp_crc_ok_q   <= 1'b0;
      err_q          <= ERR_OK;
      crc_q          <= CRC7_INIT;
      tx_go_q        <= 1'b0;
    end else begin

      if (crc_fold_en) begin
        crc_q <= crc_nxt;
      end

      clr_sync_q  <= {clr_sync_q[0],  stat_clear_tgl_i};
      clr_q       <= clr_sync_q[1];
      pres_sync_q <= {pres_sync_q[0], card_present_i};
      ramp_sync_q <= {ramp_sync_q[0], ramp_done_i};
      f1b_sync_q  <= {f1b_sync_q[0],  force_1bit_i};
      fds_sync_q  <= {fds_sync_q[0],  force_ds_i};

      if (stat_clear) stat_rty_cmd_q <= '0;

      unique case (state_q)

        C_IDLE: begin
          // Sahiplik her C_IDLE cevriminde tazelenir, komut baslayinca donar.
          init_owns_q <= init_owns;
          if (ld_valid) begin
            send55_q      <= ld_acmd;
            retry_q       <= '0;
            rsp_valid_q   <= 1'b0;
            rsp_err_q     <= 1'b0;
            rsp_crc_ok_q  <= 1'b0;
            err_q         <= ERR_OK;
            fail_is_crc_q <= 1'b0;
            word_cnt_q    <= '0;
            dat_cap_q     <= '0;
            state_q       <= C_LOAD;
          end
        end

        C_LOAD: begin
          cur_resp_q     <= send55_q ? RESP_R1 : ld_resp;
          is_long_resp_q <= (!send55_q && (ld_resp == RESP_R2));

          crc_chk_q      <= send55_q ? 1'b1 : (ld_resp != RESP_R3);

          r1_chk_q       <= send55_q ? 1'b1
                                     : ((ld_resp == RESP_R1) ||
                                        (ld_resp == RESP_R1B));

          crc_q       <= CRC7_INIT;
          tx_go_q     <= 1'b1;
          state_q     <= C_TX;
        end

        C_TX: begin
          if (tx_done_q) begin
            tx_go_q   <= 1'b0;
            crc_q     <= CRC7_INIT;

            if (cur_resp_q == RESP_NONE) begin

              timer_cnt_q <= TIMER_W'(NCC_GAP_CLK);
              gap_next_q  <= GAP_TO_IDLE;
              state_q     <= C_GAP;
            end else begin
              timer_cnt_q <= TIMER_W'(NCR_TIMEOUT_CLK);
              state_q     <= C_WAIT_RESP;
            end
          end
        end

        // Yanit yolu artik OKUYUCU'nun isi; bu kol sadece siralama yapiyor.
        C_WAIT_RESP: begin
          if (!cmd_in_i) begin
            state_q  <= C_RX;
          end else if (timer_cnt_q == '0) begin
            fail_is_crc_q <= 1'b0;
            state_q       <= C_RETRY;
          end else begin
            timer_cnt_q   <= timer_cnt_q - TIMER_W'(1);
          end
        end

        C_RX: begin
          if (rx_last) begin
            state_q <= C_EVAL;
          end
        end

        C_EVAL: begin
          timer_cnt_q <= TIMER_W'(NCC_GAP_CLK);
          if (!frame_ok) begin
            fail_is_crc_q <= 1'b1;
            state_q       <= C_RETRY;
          end else if (send55_q) begin

            send55_q   <= 1'b0;
            retry_q    <= '0;
            gap_next_q <= GAP_TO_LOAD;
            state_q    <= C_GAP;
          end else begin
            rsp_crc_ok_q <= 1'b1;
            if (r1_chk_q) begin
              card_ready_q <= resp_sh_q[R1_STATUS_LSB + R1_READY_FOR_DATA];
              if (r1_has_err) begin
                err_q     <= ERR_CMD_STATUS;
                rsp_err_q <= 1'b1;
              end
            end
            gap_next_q <= GAP_TO_IDLE;
            state_q    <= C_GAP;
          end
        end

        C_RETRY: begin
          timer_cnt_q <= TIMER_W'(NCC_GAP_CLK);
          if (retry_q < RTY_W'(CMD_RETRIES)) begin
            retry_q     <= retry_q + RTY_W'(1);
            gap_next_q  <= GAP_TO_LOAD;
            state_q     <= C_GAP;
            // Yeniden deneme komutu BASTAN gonderir, yani ACMD ise CMD55
            // onekini de bastan gonderir. Bu satir olmadan C_EVAL'de dusen
            // send55_q sifir kalir ve komut CIPLAK tekrarlanir: ACMD6 ->
            // CMD6 SWITCH_FUNC, ACMD41 -> CMD41. ld_acmd komut boyunca sabit
            // (sel_init donmus sahibe bakiyor), CMD55'in kendisi dustuyse de
            // 1 kalir, yani tek satir iki durumu da dogru kuruyor.
            send55_q    <= ld_acmd;
            // STAT_RETRY: gercekten yeniden denenen her komut, denemeyi
            // yaptiran satirin yaninda. Silme yukarida yazildigi icin
            // burada acikca eleniyor; saturasyonlu.
            if (!stat_clear && !(&stat_rty_cmd_q)) begin
              stat_rty_cmd_q <= stat_rty_cmd_q + STAT_RTY_W'(1);
            end
          end else begin
            state_q <= C_ERROR;
          end
        end

        C_GAP: begin
          if (timer_cnt_q != '0) begin
            timer_cnt_q <= timer_cnt_q - TIMER_W'(1);
          end else if (gap_next_q == GAP_TO_LOAD) begin
            state_q <= C_LOAD;
          end else begin
            state_q <= C_FIN;
          end
        end

        C_ERROR: begin
          err_q     <= fail_is_crc_q ? ERR_CMD_CRC : ERR_CMD_TIMEOUT;
          rsp_err_q <= 1'b1;
          state_q   <= C_FIN;
        end

        // =====================================================================
        // C_FIN -- komutun bittigi TEK nokta, dolayisiyla cevabin dagitildigi
        // tek nokta. Iki tuketici var ve ikisi birbirini dislar, o yuzden
        // cevap tablosu da bir kere kuruluyor: merdiven kosuyorsa merdivenin
        // tablosu, kosmuyorsa sistem yolunun rsp_valid darbesi.
        // rsp_err_q ve err_q bu cevrimde ikisi de gecerli (C_EVAL ya da
        // C_ERROR onceki cevrimde yazdi).
        // =====================================================================
        C_FIN: begin
          state_q <= C_IDLE;

          if (!init_owns_q) begin
            // ---- SISTEM yolu: cevabi L3 isler ----
            rsp_valid_q <= 1'b1;
          end else if (rsp_err_q && (step_cnt != 4'd2)) begin
            // ---- MERDIVEN: komut katmani hatasi (ACMD41 harici) ----
            init_err_code_q <= err_q;
            init_mode_q     <= INIT_ERR;
          end else begin
            // ---- MERDIVENIN CEVAP TABLOSU ----
            // Varsayilan bir sonraki adim; adima ozel kollar bunu ezer.
            step_cnt <= step_cnt + 4'd1;

            case (step_cnt)

              4'd1: begin   // CMD8: gerilim + kontrol deseni echo'su
                if ((rsp_data[15:8] == 8'hAA) && (rsp_data[19:16] == 4'h1)) begin
                  wait_cnt_q <= WAIT_W'(ACMD41_TIMEOUT_CLK);
                end else begin
                  init_err_code_q <= ERR_UNSUPPORTED;
                  init_mode_q     <= INIT_ERR;
                end
              end

              4'd2: begin   // ACMD41: kart hazir olana kadar yoklanir
                if (!rsp_err_q && rsp_data[39]) begin
                  block_addr_q <= rsp_data[38];
                end else if (wait_cnt_q == '0) begin
                  // step_cnt stays put: the default above already advanced it,
                  // and without this the ladder records a rung it never ran.
                  // Nothing downstream reads step_cnt after INIT_ERR, so this
                  // cost nothing until the step number became observable -- at
                  // which point it said the ladder died at CMD2 when it had in
                  // fact never got past ACMD41.
                  step_cnt        <= 4'd2;
                  init_err_code_q <= ERR_INIT;
                  init_mode_q     <= INIT_ERR;
                end else begin
                  step_cnt <= 4'd2;        // ayni adimi tekrar cek
                end
              end

              4'd4: rca_q <= rsp_data[39:24];          // CMD3

              4'd5: begin                               // CMD9: CSD
                // CSD_STRUCTURE != 1 -> CSD v1.0, yani SDSC. DESTEKLENMIYOR
                // ve bu yuzden ACIKCA reddediliyor (R-FUNC-5). Desteklemek
                // ikinci bir kapasite formulu, CMD16 ile blok uzunlugu ve
                // byte adresleme yolu demekti; bu kadar donanimi 2 GB alti
                // kartlar icin tasimaya degmez. Reddetmek ise BEDAVA: alan
                // zaten R2 okuyucusunda yakalaniyor, burada tek karsilastirma.
                //
                // Eskiden bu kol yoktu ve asagidaki v2 formulu KOSULSUZ
                // calisiyordu: SDSC bir kartta kapasite cop cikiyor, CCS=0
                // oldugu icin byte adresleme seciliyor ve merdiven "basarili"
                // bitiyordu -- yani kart sessizce yanlis isleniyordu.
                if (csd_struct_q != 2'b01) begin
                  init_err_code_q <= ERR_UNSUPPORTED;
                  init_mode_q     <= INIT_ERR;
                end else begin
                  card_blk_q <= { (rsp_data[69:48] + 22'd1), 10'b0 };
                  speed_q    <= SPEED_DS;
                  clk_div_q  <= CFG_CLK_W'(CLK_DIV_DS);
                end
              end

              4'd6: begin                               // CMD7
                if (!SCR_CHECK) begin
                  scr_4bit_q <= !force_1bit;
                  step_cnt   <= 4'd8;                   // SCR'yi atla
                end
              end

              4'd7: begin                               // ACMD51 -> DAT
                step_cnt   <= 4'd7;
                word_cnt_q <= '0;
                dat_cap_q  <= '0;
                wait_cnt_q <= WAIT_W'(DAT_TIMEOUT_CLK);
                state_q    <= C_DAT;
              end

              4'd8: begin                               // ACMD6
                bus_4bit_q <= scr_4bit_q;
                word_cnt_q <= '0;
                // force_ds: CMD6 switch'i hic denenmez, merdiven DS'te biter.
                if (!HS_ENABLE || force_ds) init_mode_q <= INIT_DONE;
              end

              4'd9: begin                               // CMD6 -> DAT
                step_cnt   <= 4'd9;
                word_cnt_q <= '0;
                dat_cap_q  <= '0;
                wait_cnt_q <= WAIT_W'(DAT_TIMEOUT_CLK);
                state_q    <= C_DAT;
              end

              default: ;
            endcase
          end
        end

        // =====================================================================
        // C_DAT -- merdivenin DAT yuku. Eskiden ayri FSM'in I_DAT durumuydu;
        // beklemeyi yapan taraf siralayici oldugu icin burada.
        // =====================================================================
        C_DAT: begin
          if (dat_rd_valid_i) begin
            if ((step_cnt == 4'd7) && (word_cnt_q == 5'd0)) begin
              dat_cap_q <= dat_rd_data_i[15:8];
            end else if ((step_cnt == 4'd9) && (word_cnt_q == 5'd4)) begin
              dat_cap_q <= dat_rd_data_i[7:0];
            end
            word_cnt_q <= word_cnt_q + 5'd1;
          end

          if (wait_cnt_q == '0) begin
            init_err_code_q <= ERR_DAT_TIMEOUT;
            init_mode_q     <= INIT_ERR;
            state_q         <= C_IDLE;
          end else if (!dat_rd_busy_i && dat_len_done) begin
            if (!dat_rd_crc_ok_i) begin
              init_err_code_q <= ERR_DAT_CRC;
              init_mode_q     <= INIT_ERR;
              state_q         <= C_IDLE;
            end else if (step_cnt == 4'd7) begin
              // scr_4bit_q "4-bit KULLANACAGIZ" demek: hem ACMD6'nin argumani
              // hem bus_4bit_q bundan turuyor, o yuzden force'u tek yerde,
              // burada uyguluyoruz -- ikisi hicbir kolda ayrisamaz.
              scr_4bit_q <= dat_cap_q[2] && !force_1bit;
              step_cnt   <= 4'd8;
              state_q    <= C_IDLE;      // siradaki komut cekilecek
            end else begin
              if (dat_cap_q[3:0] == 4'h1) begin
                clk_div_q <= CFG_CLK_W'(CLK_DIV_HS);
                speed_q   <= SPEED_HS;
              end
              init_mode_q <= INIT_DONE;
              state_q     <= C_IDLE;
            end
          end
        end

        default: state_q <= C_IDLE;
      endcase

      // ---- merdiven zamanlayicisi: ACMD41 yoklama penceresi ve DAT timeout --
      if ((((step_cnt == 4'd2) && init_owns_q) || (state_q == C_DAT)) &&
          (wait_cnt_q != '0)) begin
        wait_cnt_q <= wait_cnt_q - WAIT_W'(1);
      end

      // ---- merdivenin tetigi: rampa bitti, kart var ------------------------
      if ((init_mode_q == INIT_IDLE) && ramp_done && card_present) begin
        init_mode_q <= INIT_RUN;
        step_cnt    <= 4'd0;
      end

      // ---- kart cikarildi: ogrenilen her sey eskidi ------------------------
      // Merdiven hatta sahipse komutu da dusuruyoruz; eskiden iki ayri FSM
      // oldugu icin komut motoru devam eder, merdiven altindan resetlenirdi.
      if (!card_present && (init_mode_q != INIT_IDLE)) begin
        init_mode_q     <= INIT_IDLE;
        step_cnt        <= 4'd0;
        rca_q           <= '0;
        card_blk_q      <= '0;
        block_addr_q    <= 1'b0;
        speed_q         <= SPEED_INIT;
        bus_4bit_q      <= 1'b0;
        clk_div_q       <= CFG_CLK_W'(CLK_DIV_INIT);
        init_err_code_q <= ERR_OK;
        scr_4bit_q      <= 1'b0;
        if (init_owns_q) begin
          state_q <= C_IDLE;
          tx_go_q <= 1'b0;
          send55_q <= 1'b0;
        end
      end
    end
  end

  // Yanit yolu ic kullanici ile dis kullanici arasinda tek bir bitle
  // ayriliyor; eskiden bu alti kapi ultra_sd_top'taydi.
  assign rsp_data     = (cur_resp_q == RESP_R2)
      ? { 8'h0, csd_struct_q, 42'h0, csd_payload_q, 47'h0 }
      : { 96'h0, resp_sh_q };

  assign req_ready_o  = !init_owns && cmd_idle;
  assign rsp_valid_o  = !init_owns && rsp_valid_q;
  assign rsp_err_o    = !init_owns && rsp_err_q;
  assign rsp_data_o   = rsp_data;
  assign rsp_crc_ok_o = rsp_crc_ok_q;
  assign err_o        = err_q;

  assign card_ready_o = card_ready_q;

  // Register goruntusu 16 bit kalir; kullanilmayan ust bitler sifir.
  assign stat_retry_cmd_o = {{(16-STAT_RTY_W){1'b0}}, stat_rty_cmd_q};

  assign cmd_out_o    = cmd_out_q;
  assign cmd_oe_o     = cmd_oe_q;

  localparam int TO_W   = $clog2(ACMD41_TIMEOUT_CLK + 1);
  localparam int DTO_W  = $clog2(DAT_TIMEOUT_CLK + 1);
  localparam int WAIT_W = (TO_W > DTO_W) ? TO_W : DTO_W;

  // THE LADDER TABLE. Combinational decode of step_cnt, NOT an unpacked array
  // filled from an `initial` block.
  //
  // It was an array, and on this FPGA toolchain the one-bit column of it --
  // rom_acmd, the bit that says "this rung is an ACMD and needs a CMD55 in
  // front of it" -- synthesised to a constant zero while the wider columns kept
  // their contents. The design then sent a bare ACMD41 at the third rung, the
  // card correctly ignored an application command that was never qualified by
  // CMD55, and initialisation stopped there with a command timeout. Simulation
  // honours `initial` and passed the whole way through, so nothing caught it
  // until a capture of the CMD line on real hardware showed index 41 going out
  // where index 55 should have been.
  //
  // A case statement is what both tools agree on. Enum LITERALS are assigned
  // here, never a cast -- Icarus rejects enum casts inside always_comb, which
  // is what the array was working around in the first place.
  logic [5:0]  rom_cmd;
  resp_e       rom_resp;
  logic        rom_acmd;

  always_comb begin
    case (step_cnt)
      4'd0:    begin rom_cmd = CMD0_GO_IDLE_STATE;      rom_resp = RESP_NONE; rom_acmd = 1'b0; end
      4'd1:    begin rom_cmd = CMD8_SEND_IF_COND;       rom_resp = RESP_R7;   rom_acmd = 1'b0; end
      4'd2:    begin rom_cmd = ACMD41_SD_SEND_OP_COND;  rom_resp = RESP_R3;   rom_acmd = 1'b1; end
      4'd3:    begin rom_cmd = CMD2_ALL_SEND_CID;       rom_resp = RESP_R2;   rom_acmd = 1'b0; end
      4'd4:    begin rom_cmd = CMD3_SEND_RELATIVE_ADDR; rom_resp = RESP_R6;   rom_acmd = 1'b0; end
      4'd5:    begin rom_cmd = CMD9_SEND_CSD;           rom_resp = RESP_R2;   rom_acmd = 1'b0; end
      4'd6:    begin rom_cmd = CMD7_SELECT_CARD;        rom_resp = RESP_R1B;  rom_acmd = 1'b0; end
      4'd7:    begin rom_cmd = ACMD51_SEND_SCR;         rom_resp = RESP_R1;   rom_acmd = 1'b1; end
      4'd8:    begin rom_cmd = ACMD6_SET_BUS_WIDTH;     rom_resp = RESP_R1;   rom_acmd = 1'b1; end
      4'd9:    begin rom_cmd = CMD6_SWITCH_FUNC;        rom_resp = RESP_R1;   rom_acmd = 1'b0; end
      default: begin rom_cmd = CMD0_GO_IDLE_STATE;      rom_resp = RESP_NONE; rom_acmd = 1'b0; end
    endcase
  end

  // Merdivenin TEK sayaci: ROM'daki adim. Eskiden bunun yaninda 3 bitlik bir
  // FSM durumu ve bir istek-valid flopu daha vardi.
  logic [3:0]         step_cnt;

  /* verilator lint_off UNUSED */
  logic [2:0]         init_phase_probe;   // dalga formu / tb gozlemi icin
  assign init_phase_probe = {1'b0, init_mode_q};

`ifdef ULTRA_SD_DEBUG_PORT
  // 11 + 8 + 1 + 1 + 1 + 2 + 4 + 4 = 32. retry_q is cast rather than pasted in:
  // its width follows CMD_RETRIES, and a parameter change must not silently
  // reshape this word.
  // [63:32] is the last SHORT response's 32-bit payload -- resp_sh_q is
  // {argument, CRC7, end bit}, so the argument is [39:8]. Sampled next to the
  // step number it belongs to, this is what turns "the card went silent at
  // CMD2" into an answer: CMD2 is ignored by a card still in idle, and the only
  // thing that moves a card out of idle is ACMD41 answering with OCR bit 31
  // set. R3 carries no CRC and the frame check for it is therefore just the end
  // bit, so a misaligned R3 can pass with a busy bit that was never sent.
  // Bit 23 is the CMD line as this module sees it. A top-level inout pad in a
  // Gowin design may drive its IOBUF and nothing else -- tapping sd_cmd in the
  // board top is an EX0339 placement error -- so the observer gets the line
  // from here, where it is already in the cmd_clk domain.
  assign dbg_o = {resp_sh_q[39:8],
                  8'h0, cmd_in_i, init_mode_q, err_q, rsp_err_q, send55_q,
                  init_owns_q, 2'(retry_q), state_q, step_cnt};
`endif
  /* verilator lint_on UNUSED */

  logic [15:0]        rca_q;
  logic [31:0]        card_blk_q;
  logic               block_addr_q;
  speed_e             speed_q;
  logic               bus_4bit_q;
  logic [CFG_CLK_W-1:0] clk_div_q;
  err_e               init_err_code_q;

  logic [WAIT_W-1:0]  wait_cnt_q;
  logic [4:0]         word_cnt_q;
  /* verilator lint_off UNUSED */
  logic [7:0]         dat_cap_q;
  /* verilator lint_on UNUSED */
  logic               scr_4bit_q;

  // ---------------------------------------------------------------------------
  // Paylasilan istek yukleme katmani -- MUX YOK, tek secim seviyesi.
  //
  // Merdivenin sabitleri (ROM + arg decode) ile blok katmaninin bus'i ayni
  // always_comb icinde, ayni secim agacinda birlesiyor ve dogrudan req_*_q'ya
  // gidiyor. init_active ile step_cnt ayni LUT seviyesinde: eskiden bu is iki
  // seviyeydi (merdivenin kendi decode'u + top'un arbitrasyon mux'u).
  // ---------------------------------------------------------------------------
  // Dar sinyaller surekli atamayla (Icarus always_comb icinde enum cast'i
  // desteklemiyor), 32-bit arg yolu tek always_comb'da. Onemli olan arg
  // zaten: eskiden iki secim katmani vardi, simdi bir.
  // Uretici secimi. C_IDLE'da CANLI duruma bakar, cunku komutun (ve ACMD
  // kalifiyesinin) kabulu o cevrimde olur ve init_owns_q henuz onceki komutun
  // sahibini tutuyor -- merdiven bittikten sonraki ilk blok komutu bir ACMD
  // olabilir, o zaman CMD55 oneki dusup kart komutu reddederdi. Komut
  // basladiktan sonra DONMUS sahibe bakar, boylece cerceve ortasinda (ornegin
  // kart cikarilirsa) uretici degisip CMD55'in ardindan yanlis komut gitmez.
  logic sel_init;
  assign sel_init = cmd_idle ? init_owns : init_owns_q;

  // Gonderici CEKIYOR: merdiven kostugu surece siradaki adim her zaman hazir,
  // ayri bir valid/ready el sikismasina gerek yok.
  assign ld_valid = init_owns ? 1'b1 : req_valid_i;
  assign ld_index = sel_init    ? rom_cmd : req_index_i;
  assign ld_resp  = sel_init    ? rom_resp : req_resp_i;
  assign ld_acmd  = sel_init    ? rom_acmd : req_is_acmd_i;

  always_comb begin
    if (!sel_init) begin
      ld_arg = req_arg_i;
    end else begin
      case (step_cnt)
        4'd1:    ld_arg = 32'h0000_01AA;
        4'd2:    ld_arg = OCR_REQUEST;
        4'd5,
        4'd6:    ld_arg = {rca_q, 16'h0000};
        4'd8:    ld_arg = scr_4bit_q ? 32'h0000_0002 : 32'h0000_0000;
        4'd9:    ld_arg = 32'h80FF_FFF1;
        default: ld_arg = 32'h0000_0000;
      endcase
    end
  end

  assign dat_rd_bytes_o = (step_cnt == 4'd7) ? 11'd8 : 11'd64;

  wire dat_len_done = (step_cnt == 4'd7) ? (word_cnt_q == 5'd2)
                                         : (word_cnt_q == 5'd16);

  // Hat merdivenin mi? Tek bit, hayat dongusunden dogrudan okunuyor.
  assign init_owns  = (init_mode_q == INIT_RUN);
  assign cmd_idle   = (state_q == C_IDLE);

  // init_done / init_err icin ayri flop YOK: hayat dongusunun kendisi soyluyor.
  assign init_busy_o      = init_owns;
  assign init_done_o      = (init_mode_q == INIT_DONE);
  assign init_err_o       = (init_mode_q == INIT_ERR);
  assign init_err_code_o  = init_err_code_q;

  // DAT okumasini komutun KUYRUGUNDA arm ediyoruz, C_DAT'a girmeyi beklemeden:
  // kart veri blogunu yanitin hemen ardindan surmeye basliyor, iki cevrim geç
  // kalmak baslangic bitini kacirip CRC hatasi olarak geri geliyor. Pencere
  // yalnizca BASARILI kuyruk: C_GAP'in retry kolu (GAP_TO_LOAD) disarida,
  // yoksa yeniden denenen bir ACMD51'de bos yere arm ederdik.
  logic dat_arm_window;
  assign dat_arm_window = (state_q == C_FIN) || (state_q == C_DAT) ||
                          ((state_q == C_GAP) && (gap_next_q == GAP_TO_IDLE));

  assign dat_rd_start_o = init_owns_q && dat_arm_window &&
                          ((step_cnt == 4'd7) || (step_cnt == 4'd9)) &&
                          !dat_rd_busy_i && (word_cnt_q == '0);
  assign rca_o          = rca_q;
  assign card_blk_o     = card_blk_q;
  assign block_addr_o   = block_addr_q;
  assign speed_o        = speed_q;
  assign bus_4bit_o     = bus_4bit_q;
  assign clk_div_o      = clk_div_q;


endmodule

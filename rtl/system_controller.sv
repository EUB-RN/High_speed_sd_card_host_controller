// -----------------------------------------------------------------------------
// system_controller
//   Purpose      : L4/L3 sistem kontrolcusu.
//                  Gorevi:
//                    1. Reset siralamasi (asenkron assert, senkron release)
//                    2. Mekanik sd_cd debounce ve kart varlik/degisim tespiti
//                    3. Sistem Faz FSM'i (RESET -> CARD_DETECT -> RAMP -> CONFIG <-> XFER)
//                    4. 74-clock SD acilis rampasi (R-FUNC-2, dogrudan posedge sayaci)
//                    5. SD saat bolme ORANI ve clock gating enable (bolucunun
//                       kendisi artik ultra_sd_phy_gowin icinde)
//                    6. Veri yolu genisligi: tek bit (0 = 1-bit, 1 = 4-bit)
//                    7. L3 transfer izni seviyesi (xfer_go_o)
//                    8. Table 5-1 durum/hata/IRQ goruntusu
//
//                  ultra_sd_stat diye bir modul YOK. Table 5-1 bu modulun faz
//                  FSM'inin icine dagildi: "fin" ve "fail" FSM'in zaten aldigi
//                  xfer_done_i / xfer_err_i sinyalleridir, yani DONE ve ERR
//                  gecisi yaptiran satirin yaninda, SYS_READ/SYS_WRITE kolunda
//                  kuruluyor -- ayri bir blok da, ayri bir port da gereksiz.
//
//                  Table 5-2 SAYACLARI ise burada DEGIL: her biri olayini
//                  ureten FSM'in icinde ve o FSM'in saatinde duruyor
//                  (R-IF-11), cunku olay orada bir case kolu; burada olsalar
//                  o kollari yeniden kodlamak ve saat alanini yeniden kurmak
//                  gerekirdi. Dagilim:
//                    STAT_DATA, STAT_BUSY       -> ultra_sd_line
//                    STAT_GAP, STAT_RETRY[15:0] -> ultra_sd_block
//                    STAT_RETRY[31:16]          -> ultra_sd_cmd
//                  ucu de tek bolunmus SD saatinde (sd_clk_i ile ayni ag).
//                  Bu modulun sayaclara tek katkisi silme komutu: CTRL darbesi
//                  burada toggle'a cevrilip ucune de dagitilir (cdc.md 9).
//                  Saatler MUX'a sokulmaz; Clock Gating (DQCE) ile surulur.
//                  Bu modul hicbir saat URETMEZ: yalnizca oran + enable verir,
//                  gate'lenmis SD saatini geri girdi olarak alir.
// -----------------------------------------------------------------------------

module system_controller
  import ultra_sd_pkg::*;
#(
  parameter int CD_DEBOUNCE_CYC = 100_000,
  parameter int RST_SYNC_STAGES = 2,
  parameter int RAMP_CLOCKS     = 74,
  parameter int INIT_CLK_DIV    = 250,
  // Saat kesilmeden once L2/L3'e verilen temizlik payi, SD cevrimi cinsinden.
  // Unwind'in en uzun hali CMD12 + CMD13, her biri (CMD_RETRIES+1) denemeyle:
  // ~(48 tx + 64 Ncr + 8 Ncc) x 4 x 2 ~= 1050 cevrim. 4096 iki kattan fazla
  // pay birakiyor ve 13 bitlik tek sayac demek.
  parameter int DRAIN_SD_CLK    = 4096
) (
  input  logic                            clk,
  input  logic                            rst_n_i,
  input  logic                            soft_reset_i,
  input  logic                            stat_clear_i,
  input  logic                            sd_cd_i,

  // Oran ve faz kontrolu
  input  logic [CFG_CLK_W-1:0]            clk_div_i,
  input  logic                            init_done_i,
  input  logic                            start_i,
  input  logic                            dir_i,
  input  logic                            abort_i,
  input  logic                            xfer_done_i,
  input  logic                            xfer_err_i,

  // Gercek genislik: merdiven CFG_PHY.FORCE_1BIT'i ZATEN uyguladi (ACMD6'nin
  // argumaninda), yani burada ikinci bir daraltma katmani YOK. Eskiden vardi
  // ve yanlisti: host 1-bit'e dusuyor, kart 4-bit'te kaliyordu.
  input  logic                            bus_4bit_i,

  // Reset cikislari
  output logic                            rst_n_o,
  output logic                            core_rst_n_o,

  // Kart durumu
  output logic                            card_present_o,
  output logic                            card_change_o,

  // Bolme orani ve gate enable (PHY'daki clk_controller / DQCE'ye gider)
  output logic [CFG_CLK_W-1:0]            sd_clk_ratio_o,
  output logic                            sd_clk_en_o,

  // Rampa sayimi icin gate'lenmis SD saati (posedge ile sayilir)
  input  logic                            sd_clk_i,

  // L1'e veri yolu genisligi: 1 = 4-bit (DAT0..3), 0 = 1-bit (yalniz DAT0)
  output logic                            bus_wide_o,

  // L3'e transfer izni
  output logic                            xfer_go_o,

  // Transfer GERCEKTEN basladi: tek cevrimlik darbe, faz CONFIG -> READ/WRITE
  // gecisinde. L4'un okuma akis master'i bununla arm edilir; CTRL.START'in
  // kendisiyle DEGIL, cunku kabul edilmeyen bir START akisi bos yere arm edip
  // sururcuyu hic gelmeyecek beat'leri beklerken birakiyordu.
  output logic                            xfer_launch_o,

  // Sistem fazi ve bildirimler
  output sys_phase_e                      sys_phase_o,
  output logic                            ramp_done_o,
  output logic                            cfg_start_o,

  // ---- Table 5-1 olay girisleri ---------------------------------------------
  // fin / fail ayri port DEGIL: faz FSM'inin zaten aldigi xfer_done_i ve
  // xfer_err_i ayni iki sinyaldir (L3'un fin_o / fail_o cikislari).
  input  logic                            accept_i,
  input  logic                            busy_i,
  input  err_e                            fail_code_i,
  input  logic                            card_ready_i,
  input  speed_e                          speed_i,
  input  logic                            init_err_i,
  input  err_e                            init_err_code_i,

  // ---- Table 5-1 register goruntusu -----------------------------------------
  output logic [STATUS_W-1:0]             status_o,
  output err_e                            err_o,
  output logic [1:0]                      irq_set_o,

  // ---- Table 5-2 sayaclarina silme komutu (cdc.md 9) ------------------------
  // CTRL.STAT_CLEAR tek clk cevrimi genisliginde; sayaclar daha yavas SD
  // saatlerinde kostugu icin darbe kaybolurdu. Toggle genislikten bagimsiz:
  // ureten biti cevirir, tuketen DEGISIME bakar, ikisi de boleni bilmez.
  output logic                            stat_clear_tgl_o
);

  localparam int SOFT_RST_CYC = 16;
  localparam int SOFT_CNT_W   = $clog2(SOFT_RST_CYC + 1);
  localparam int CD_CNT_W     = $clog2(CD_DEBOUNCE_CYC + 1);
  localparam int RAMP_CNT_W   = $clog2(RAMP_CLOCKS + 1);
  localparam int DRAIN_CNT_W  = $clog2(DRAIN_SD_CLK + 1);

  // ---------------------------------------------------------------------------
  // 1. Reset senkronizasyonu (Asenkron assert, senkron release)
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
  // 2. Soft Reset sayaci (Carry-chain dogal yukari sayac)
  // ---------------------------------------------------------------------------
  logic                  soft_rst_n_q;
  logic [SOFT_CNT_W-1:0] soft_cnt_q;

  always_ff @(posedge clk or negedge rst_n_o) begin
    if (!rst_n_o) begin
      soft_rst_n_q <= 1'b1;
      soft_cnt_q   <= '0;
    end else if (soft_reset_i) begin
      soft_rst_n_q <= 1'b0;
      soft_cnt_q   <= '0;
    end else if (!soft_rst_n_q) begin
      if (soft_cnt_q == SOFT_CNT_W'(SOFT_RST_CYC)) begin
        soft_rst_n_q <= 1'b1;
        soft_cnt_q   <= '0;
      end else begin
        soft_cnt_q   <= soft_cnt_q + SOFT_CNT_W'(1);
      end
    end
  end

  assign core_rst_n_o = rst_n_o & soft_rst_n_q;

  // ---------------------------------------------------------------------------
  // 3. Kart Algilama ve Mekanik Debounce (Yukari sayac)
  // ---------------------------------------------------------------------------
  logic [1:0]        cd_sync_q;
  logic              cd_raw;
  logic              cd_stable_q;
  logic [CD_CNT_W-1:0] cd_cnt_q;
  logic              card_present_q;
  logic              card_change_q;
  // CARD_READY'nin yukselen kenari, card_change_q ile AYNI flopa dusuyor:
  // ikisi de "git STATUS'u oku" demek, ikisi de tek cevrimlik darbe olmali.
  logic              rdy_d_q;

  assign cd_raw = cd_sync_q[1];

  always_ff @(posedge clk or negedge rst_n_o) begin
    if (!rst_n_o) begin
      cd_sync_q      <= 2'b11; // active-low pull-up: kart yok
      cd_stable_q    <= 1'b1;
      cd_cnt_q       <= '0;
      card_present_q <= 1'b0;
      card_change_q  <= 1'b0;
      rdy_d_q        <= 1'b0;
    end else begin
      cd_sync_q     <= {cd_sync_q[0], sd_cd_i};
      rdy_d_q       <= card_ready_i;

      // Varsayilan sifir; asagidaki IKI olaydan biri onu bu cevrim icin kurar.
      card_change_q <= card_ready_i & ~rdy_d_q;

      if (cd_raw == cd_stable_q) begin
        cd_cnt_q <= '0;
      end else if (cd_cnt_q == CD_CNT_W'(CD_DEBOUNCE_CYC)) begin
        cd_cnt_q       <= '0;
        cd_stable_q    <= cd_raw;
        card_present_q <= ~cd_raw; // ped aktif alcaktir
        card_change_q  <= 1'b1;
      end else begin
        cd_cnt_q       <= cd_cnt_q + CD_CNT_W'(1);
      end
    end
  end

  assign card_present_o = card_present_q;
  assign card_change_o  = card_change_q;

  // ---------------------------------------------------------------------------
  // CARD_CHANGE: kartin KULLANILABILIRLIGI degisti.
  //
  // Iki olay var ve ikisi de surucunun ayni seyi yapmasini gerektirir -- git
  // STATUS'u oku: (1) ped debounce'u kart takildi/cikarildi diyor, (2) merdiven
  // bitti ve CARD_READY kalkti.
  //
  // Ikincisi eskiden HICBIR kesme uretmiyordu: init basarisiz olunca IRQ_ERR
  // cikiyor, BASARILI olunca hicbir sey cikmiyordu. Surucunun elinde kart
  // takildigindaki CARD_CHANGE vardi, ondan sonrasi STATUS.CARD_READY'yi
  // yoklamakti. START'i artik ERR_CARD_STATE ile acikca reddettigimiz icin
  // "ne zaman deneyebilirim" sorusunun bir cevabi olmak zorunda.
  //
  // Yeni bir IRQ biti ACILMADI, cunku Table 5-1'in register haritasi normatif
  // (R-IF-2). Bunun yerine var olan bitin kapsami kartin varligindan kartin
  // KULLANILABILIRLIGINE genisledi. Uretimi yukaridaki debounce flopunda,
  // card_change_q'nun kendisinde -- boylece iki olay da ayni genislikte,
  // registered, tek cevrimlik darbe.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // 4. Faz FSM'i: gecisler, 74-clock rampa, veri yolu genisligi, Table 5-1
  //    durum/hata/IRQ ve STAT_CLEAR toggle'i -- hepsi TEK always_ff.
  // ---------------------------------------------------------------------------
  sys_phase_e            phase_q;
  logic                  start_pending_q;
  logic                  xfer_launch_q;
  logic                  cfg_start_q;
  logic [RAMP_CNT_W-1:0] ramp_cnt_q;
  logic                  ramp_done_q;

  // Veri yolu genisligi: yalnizca iki gecerli desen var (1-bit / 4-bit), yani
  // tasinan bilgi tek bittir -- 4 flopluk maske yerine 1 flop. Maskeyi
  // hatlara acan taraf L1.
  logic                  bus_wide_q;

  // Table 5-1
  logic                  done_q, done_d_q;
  logic                  err_seen_q, err_d_q;
  logic                  init_err_d_q;
  err_e                  err_q;

  logic                  stat_clear_tgl_q;

  // Transfer fazi: genislik kilidi ve L3 izni bunun uzerinden.
  logic                  line_phase;
  assign line_phase = (phase_q == SYS_READ) || (phase_q == SYS_WRITE);

  // Rampa sayaci: SD saatinin gercek posedge'inde dogal yukari sayar (0 -> RAMP_CLOCKS)
  always_ff @(posedge sd_clk_i or negedge core_rst_n_o) begin
    if (!core_rst_n_o) begin
      ramp_cnt_q  <= '0;
      ramp_done_q <= 1'b0;
    end else if (phase_q != SYS_RAMP) begin
      ramp_cnt_q  <= '0;
      ramp_done_q <= 1'b0;
    end else if (!ramp_done_q) begin
      if (ramp_cnt_q == RAMP_CNT_W'(RAMP_CLOCKS - 1)) begin
        ramp_cnt_q  <= ramp_cnt_q + RAMP_CNT_W'(1);
        ramp_done_q <= 1'b1;
      end else begin
        ramp_cnt_q  <= ramp_cnt_q + RAMP_CNT_W'(1);
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n_o) begin
    if (!rst_n_o) begin
      phase_q          <= SYS_RESET;
      start_pending_q  <= 1'b0;
      xfer_launch_q    <= 1'b0;
      cfg_start_q      <= 1'b0;
      bus_wide_q       <= 1'b0;
      done_q           <= 1'b0;
      done_d_q         <= 1'b0;
      err_seen_q       <= 1'b0;
      err_d_q          <= 1'b0;
      init_err_d_q     <= 1'b0;
      err_q            <= ERR_OK;
      stat_clear_tgl_q <= 1'b0;
    end else begin
      cfg_start_q   <= 1'b0;
      xfer_launch_q <= 1'b0;

      // IRQ'lar kenar uretir: bir cevrimlik gecikme hatti.
      done_d_q     <= done_q;
      err_d_q      <= err_seen_q;
      init_err_d_q <= init_err_i;

      // CTRL.STAT_CLEAR darbesi -> toggle. Sayaclar bu bitin DEGISIMINI
      // komut olarak alir; hangi SD saatinde kostuklari onemli degil.
      if (stat_clear_i) stat_clear_tgl_q <= ~stat_clear_tgl_q;

      // Table 5-1'in uc olayi da faz koluna KONULAMAZ, ve bunun somut bir
      // sebebi var: abort yolunda FSM SYS_READ/SYS_WRITE'tan abort_i ile
      // cikar, L3 ise unwind'i (CMD12 STOP) bitirdikten SONRA fin/fail
      // bildirir -- yani faz coktan SYS_CONFIG'tir. Kolun icinde olsalardi
      // iptal edilen bir transferde DONE hic kurulmaz ve surucu STATUS'u
      // sonsuza kadar yoklardi. accept_i de ayni sekilde gecikmeli gelir.
      // O yuzden bu uclu FSM'in kendi always_ff'inde, ama fazdan bagimsiz.
      if (accept_i) begin
        done_q     <= 1'b0;
        err_seen_q <= 1'b0;
        err_q      <= ERR_OK;
      end else if (xfer_done_i) begin
        done_q     <= 1'b1;
      end

      if (xfer_err_i) begin
        err_q      <= fail_code_i;
        err_seen_q <= 1'b1;
      end

      // Genislik kilidi: transfer fazinda donar, disinda istegi izler.
      if (!line_phase) begin
        bus_wide_q <= bus_4bit_i;
      end

      // -----------------------------------------------------------------
      // CTRL.START kabul edilemiyorsa SESSIZ KALMAK yok: sebebi ERR'e yazilir
      // ve IRQ_ERR kenari cikar. Eskiden bu kol yalnizca init_done_i ile
      // kapiliydi, yani CARD_READY=0 iken yazilan START hicbir iz birakmadan
      // kayboluyordu: ne DONE, ne ERR. L3'teki ERR_CARD_STATE kontrolu de
      // devreye giremiyordu, cunku xfer_go hic kalkmiyordu -- surucunun tek
      // gordugu sey STATUS'un hic degismemesiydi.
      //
      // Istegi ASKIYA ALMAK (bufferlamak) yerine reddetmek bilincli bir
      // tercih: askidaki istek surucuye "kuyruktayim" ile "kilitlendim"i
      // ayirt ettirmez ve bir de iptal yolu ister. Hata yolu zaten var.
      // Tek istisna asagidaki start_pending_q: BITMEKTE olan bir transferin
      // son cevriminde gelen START, sirayla kabul edilir (back-to-back).
      // -----------------------------------------------------------------
      if (start_i) begin
        if (!card_present_q) begin
          err_q      <= ERR_NO_CARD;
          err_seen_q <= 1'b1;
        end else if (!init_done_i) begin
          err_q      <= ERR_CARD_STATE;
          err_seen_q <= 1'b1;
        end else if (line_phase && !xfer_done_i && !xfer_err_i) begin
          // Devam eden transferin ustune START: sira hatasi.
          err_q      <= ERR_PROTOCOL;
          err_seen_q <= 1'b1;
        end else begin
          start_pending_q <= 1'b1;
        end
      end

      unique case (phase_q)
        SYS_RESET: begin
          if (soft_rst_n_q && !soft_reset_i) begin
            phase_q <= SYS_CARD_DETECT;
          end
        end

        SYS_CARD_DETECT: begin
          if (card_present_q) begin
            phase_q <= SYS_RAMP;
          end
        end

        SYS_RAMP: begin
          if (ramp_done_q) begin
            phase_q     <= SYS_CONFIG;
            cfg_start_q <= 1'b1;
          end
        end

        SYS_CONFIG: begin
          if ((start_i || start_pending_q) && init_done_i &&
              !xfer_done_i && !xfer_err_i) begin
            phase_q         <= dir_i ? SYS_WRITE : SYS_READ;
            start_pending_q <= 1'b0;
            xfer_launch_q   <= 1'b1;
          end
        end

        SYS_READ, SYS_WRITE: begin
          if (xfer_done_i || xfer_err_i || abort_i) begin
            phase_q <= SYS_CONFIG;
          end
        end

        default: phase_q <= SYS_RESET;
      endcase

      // Oncelikli gecisler. Kart cikarmak Table 5-1'i SILMEZ: surucu hala
      // bitmis bir transferin sonucunu okuyor olabilir. Soft reset ise
      // rst_n_o'nun senkron karsiligi, o yuzden ayni alanlari temizler.
      if (!card_present_q && (phase_q != SYS_RESET)) begin
        phase_q         <= SYS_CARD_DETECT;
        cfg_start_q     <= 1'b0;
        start_pending_q <= 1'b0;
        xfer_launch_q   <= 1'b0;
      end
      if (soft_reset_i) begin
        phase_q         <= SYS_RESET;
        cfg_start_q     <= 1'b0;
        start_pending_q <= 1'b0;
        xfer_launch_q   <= 1'b0;
        bus_wide_q      <= 1'b0;
        done_q          <= 1'b0;
        err_seen_q      <= 1'b0;
        err_q           <= ERR_OK;
      end
    end
  end

  assign sys_phase_o = phase_q;
  assign ramp_done_o = ramp_done_q || (phase_q == SYS_CONFIG) ||
                       (phase_q == SYS_READ)   ||
                       (phase_q == SYS_WRITE);
  assign cfg_start_o   = cfg_start_q;
  assign xfer_launch_o = xfer_launch_q;
  assign xfer_go_o   = line_phase;   // L3 transfer izni, seviye
  assign bus_wide_o  = bus_wide_q;

  // Table 5-1 register goruntusu ve IRQ kenarlari (yukaridaki FSM'in cikisi).
  assign err_o = err_seen_q ? err_q
               : init_err_i ? init_err_code_i
                            : ERR_OK;

  assign irq_set_o[IRQ_DONE_BIT] = done_q & ~done_d_q;
  assign irq_set_o[IRQ_ERR_BIT]  = (err_seen_q & ~err_d_q) |
                                   (init_err_i & ~init_err_d_q);

  // card_present port uzerinden gelmiyor: debounce'u bu modul yapiyor.
  assign status_o[STATUS_BUSY_BIT]           = busy_i;
  assign status_o[STATUS_DONE_BIT]           = done_q;
  assign status_o[STATUS_CARD_PRES_BIT]      = card_present_q;
  assign status_o[STATUS_CARD_RDY_BIT]       = card_ready_i;
  assign status_o[STATUS_SPEED_LSB +: 2]     = speed_i;
  // Table 5-1 genislik alani L1'in GERCEKTEN surdugu maskeyi soyler
  // (bus_wide_q, transfer boyunca donmus olan), kartin yetenegini degil.
  assign status_o[STATUS_BUS_WIDTH_LSB +: 2] = {1'b0, bus_wide_q};

  assign stat_clear_tgl_o = stat_clear_tgl_q;

  // ---------------------------------------------------------------------------
  // 5. Saat Bolme Orani ve Gate Enable Kontrolu
  // ---------------------------------------------------------------------------
  logic                 sd_clk_en;
  logic [CFG_CLK_W-1:0] sd_clk_div;

  // ---------------------------------------------------------------------------
  // Temizlik payi (drain). phase_ok dustugu anda saati kesmek, kesilen saatin
  // ustunde kosan FSM'lerin cikis yolunu da kesiyordu: kart transfer sirasinda
  // cekilirse L3'un abort/unwind kolu (CMD12 + CMD13 -> S_ERROR) ve L2'nin
  // "kart gitti, ogrenilenler eskidi" kolu hic cevrim gormuyor, STATUS.BUSY
  // 1'de donuyor ve DONE/ERR/IRQ hic gelmiyordu (R-FUNC-14/16). Simdi L3
  // mesgulse saat ACIK kaliyor, ama sinirsiz degil: sayac dolunca gate yine
  // kapaniyor, yani asili bir L3 saati sonsuza kadar tutamaz (R-FUNC-17).
  //
  // Sayac SD saatinde (sd_clk_i) duruyor, clk'te degil: pencere bolenden
  // bagimsiz olsun diye. Maliyeti tek 13-bit sayac + 1 flop; phase_ok iyiyken
  // surekli yeniden yuklendigi icin her gate olayi tam pencereyle basliyor.
  // ---------------------------------------------------------------------------
  logic                   phase_ok;
  logic [DRAIN_CNT_W-1:0] drain_cnt_q;
  logic                   drain_done_q;

  assign phase_ok = (phase_q != SYS_RESET) && (phase_q != SYS_CARD_DETECT);

  always_ff @(posedge sd_clk_i or negedge core_rst_n_o) begin
    if (!core_rst_n_o) begin
      drain_cnt_q  <= DRAIN_CNT_W'(DRAIN_SD_CLK);
      drain_done_q <= 1'b0;
    end else if (phase_ok) begin
      drain_cnt_q  <= DRAIN_CNT_W'(DRAIN_SD_CLK);
      drain_done_q <= 1'b0;
    end else if (drain_cnt_q != '0) begin
      drain_cnt_q  <= drain_cnt_q - DRAIN_CNT_W'(1);
    end else begin
      drain_done_q <= 1'b1;
    end
  end

  assign sd_clk_en  = phase_ok || (busy_i && !drain_done_q);
  assign sd_clk_div = (phase_q == SYS_RAMP) ? CFG_CLK_W'(INIT_CLK_DIV)
                                            : clk_div_i;

  assign sd_clk_en_o    = sd_clk_en;
  assign sd_clk_ratio_o = sd_clk_div;

endmodule

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
//                    STAT_DATA, STAT_BUSY       -> ultra_sd_line  (line_clk)
//                    STAT_GAP, STAT_RETRY[15:0] -> ultra_sd_block (cmd_clk)
//                    STAT_RETRY[31:16]          -> ultra_sd_cmd   (cmd_clk)
//                  Bu modulun sayaclara tek katkisi silme komutu: CTRL darbesi
//                  burada toggle'a cevrilip ucune de dagitilir (cdc.md 9).
//                  Saatler MUX'a sokulmaz; Clock Gating (DQCE) ile surulur.
//                  Bu modul hicbir saat URETMEZ: yalnizca oran + enable verir,
//                  gate'lenmis cmd_clk'i geri girdi olarak alir.
// -----------------------------------------------------------------------------

module system_controller
  import ultra_sd_pkg::*;
#(
  parameter int CD_DEBOUNCE_CYC = 100_000,
  parameter int RST_SYNC_STAGES = 2,
  parameter int RAMP_CLOCKS     = 74,
  parameter int INIT_CLK_DIV    = 250
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

  input  logic                            bus_4bit_i,
  input  logic                            force_1bit_i,

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
  input  logic                            cmd_clk_i,

  // L1'e veri yolu genisligi: 1 = 4-bit (DAT0..3), 0 = 1-bit (yalniz DAT0)
  output logic                            bus_wide_o,

  // L3'e transfer izni
  output logic                            xfer_go_o,

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

  assign cd_raw = cd_sync_q[1];

  always_ff @(posedge clk or negedge rst_n_o) begin
    if (!rst_n_o) begin
      cd_sync_q      <= 2'b11; // active-low pull-up: kart yok
      cd_stable_q    <= 1'b1;
      cd_cnt_q       <= '0;
      card_present_q <= 1'b0;
      card_change_q  <= 1'b0;
    end else begin
      cd_sync_q     <= {cd_sync_q[0], sd_cd_i};
      card_change_q <= 1'b0;

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
  // 4. Faz FSM'i: gecisler, 74-clock rampa, veri yolu genisligi, Table 5-1
  //    durum/hata/IRQ ve STAT_CLEAR toggle'i -- hepsi TEK always_ff.
  // ---------------------------------------------------------------------------
  sys_phase_e            phase_q;
  logic                  start_pending_q;
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
  always_ff @(posedge cmd_clk_i or negedge core_rst_n_o) begin
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
      cfg_start_q <= 1'b0;

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
        bus_wide_q <= bus_4bit_i & ~force_1bit_i;
      end

      if (start_i && init_done_i &&
          ((phase_q == SYS_CONFIG) || xfer_done_i || xfer_err_i))
        start_pending_q <= 1'b1;

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
      end
      if (soft_reset_i) begin
        phase_q         <= SYS_RESET;
        cfg_start_q     <= 1'b0;
        start_pending_q <= 1'b0;
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
  assign cfg_start_o = cfg_start_q;
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
  assign status_o[STATUS_BUS_WIDTH_LSB +: 2] = {1'b0, bus_4bit_i};

  assign stat_clear_tgl_o = stat_clear_tgl_q;

  // ---------------------------------------------------------------------------
  // 5. Saat Bolme Orani ve Gate Enable Kontrolu
  // ---------------------------------------------------------------------------
  logic                 sd_clk_en;
  logic [CFG_CLK_W-1:0] sd_clk_div;

  assign sd_clk_en  = (phase_q != SYS_RESET) && (phase_q != SYS_CARD_DETECT);
  assign sd_clk_div = (phase_q == SYS_RAMP) ? CFG_CLK_W'(INIT_CLK_DIV)
                                            : clk_div_i;

  assign sd_clk_en_o    = sd_clk_en;
  assign sd_clk_ratio_o = sd_clk_div;

endmodule

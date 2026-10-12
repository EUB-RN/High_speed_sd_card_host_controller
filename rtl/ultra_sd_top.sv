// -----------------------------------------------------------------------------
// ultra_sd_top
//   Purpose      : Integration wrapper. SD pad instantiation via the PHY, AXI
//                  ports out to the harness. Wiring only -- no logic beyond
//                  module instances is permitted here (R-ARCH-1, Table 4-1).
//   Clock domain : clk (system clock, SYS_CLK_HZ)
//   Reset scheme : rst_n, asynchronous assert / synchronous deassert (R-CLK-1)
//   Implements   : Spec Section 5.2 (normative port list, Figure 5-1)
//   Note         : The port list below is normative and exact. The harness
//                  instantiates this module and nothing else (Figure 4-1).
//
//   ---------------------------------------------------------------------------
//   HIYERARSI (Figure 4-1)
//   ---------------------------------------------------------------------------
//     u_sysctl  system_controller   reset, kart algilama, faz FSM'i, saat
//                                   bolme ORANI + gate enable, Table 5-1
//                                   durum goruntusu, STAT_CLEAR toggle'i
//     u_axi     ultra_sd_axi_top    L4: AXI4-Lite + register dosyasi + iki
//                                   AXI4-Stream adaptoru (async FIFO'lar)
//     u_block   ultra_sd_block      L3: LBA siralamasi, blok akisi
//     u_cmd     ultra_sd_protocol   L2: init/block request ownership and wiring
//       u_init  ultra_sd_init       card initialization and configuration
//       u_engine ultra_sd_cmd       command framing and response transport
//         u_tx   ultra_sd_cmd_tx   CMD serialiser; split out for R-ARCH-3
//     u_line    ultra_sd_line       L1: DAT cerceveleme
//     u_phy     ultra_sd_phy_gowin  L0: pedler, uc-durum, ornekleme fazi
//
//   ---------------------------------------------------------------------------
//   SAAT ALANLARI
//   ---------------------------------------------------------------------------
//   clk          : L4 (AXI), system_controller, PHY'nin kontrol mantigi
//   sd_clk_core  : L1, L2, L3 ve rampa sayaci -- TEK bolunmus SD saati
//   Saat yolu iki parcaya bolunmustur:
//     ultra_sd_phy_gowin        BOLER + GATE'LER -> clk_controller, DQCE
//     faz FSM'i (system_controller)  KARAR       -> oran + enable
//   Bolunmus (ham) saat artik hicbir modul siniri gecmiyor: sysctl'den PHY'a
//   yalnizca bir SAYI (oran) ve bir enable gider, PHY'dan geri gate'lenmis
//   saat tuketicilere ve rampa sayacina doner.
//   Burada eskiden iki saat vardi (cmd_clk / line_clk) ve aralarinda bir DCS:
//   ikisi ayni bolucuden ayni oranla ciktigi, secim biti sabit 0 baglandigi ve
//   enable'lari ayni tel oldugu icin ucu de olu mantikti. Tek dalga formuna
//   iki global saat agi harcaniyor, STA iki ayri base clock goruyor ve
//   L1 <-> L3 yollari bos yere saatler-arasi analiz ediliyordu. Simdi tek
//   saat var; L1/L2/L3 arasi yollar ayni-saat yollaridir.
//   clk <-> sd_clk_core gecisleri doc/cdc.md 1, 2 ve 6 numarali satirlardir ve
//   tamami tuketici modulun ICINDE cozulur; burada senkronizer YOKTUR.
//
//   ---------------------------------------------------------------------------
//   TABLE 5-2 SAYACLARI
//   ---------------------------------------------------------------------------
//   Ayri bir istatistik modulu YOK. Her sayac olayini URETEN FSM'in icinde ve
//   o FSM'in saatinde durur (R-IF-11), cunku olay orada bir case kolu:
//     STAT_DATA, STAT_BUSY       u_line   (sd_clk_core)
//     STAT_GAP, STAT_RETRY[15:0] u_block  (sd_clk_core)
//     STAT_RETRY[31:16]          u_cmd    (sd_clk_core)
//   Bu dosyanin payi yalnizca STAT_CLEAR toggle'ini ucune dagitmak ve iki
//   yeniden deneme yarisini tek registera birlestirmek.
//
// -----------------------------------------------------------------------------
module ultra_sd_top #(
  parameter int SYS_CLK_HZ     = 100_000_000, // supplied by harness
  parameter int DATA_W         = 32,          // AXIS payload width
  parameter int RD_FIFO_BLOCKS = 4,
  parameter int WR_FIFO_BLOCKS = 2,
  parameter int CRC_RETRIES    = 3,
  // SD clocks between the end of one command frame (or its response) and the
  // start of the next. The spec's NCC/NRC minimum is 8 and that is the default,
  // but it is a MINIMUM: a card that is slow to release CMD after a response
  // misses a command sent exactly on it, and the symptom is the next command
  // going unanswered with no error anywhere -- the card simply never saw it.
  // Exposed so a board can be given more margin without editing this file.
  parameter int NCC_GAP_CLK    = 8,
  // Data-wait timeouts in SD clocks. Zero means "derive from SYS_CLK_HZ", which
  // is what a real build wants and what the numbers below do. They are exposed
  // because a testbench cannot reach them otherwise: the derived programming
  // timeout is half a second of SD clocks, which at a simulation's clock rate
  // is a second of simulated time, so the one error path that is defined by the
  // timeout firing -- a card that never releases DAT0 -- could not be tested at
  // all. Overriding them is also what R-DEG-7 asks for in general: adapting to
  // a slower card should be a parameter, not an edit.
  parameter int NAC_TIMEOUT_CLK_P  = 0,
  parameter int PROG_TIMEOUT_CLK_P = 0
) (
  input  logic              clk,            // system clock, SYS_CLK_HZ
  input  logic              rst_n,          // async assert, sync deassert

  // ---- AXI4-Lite slave: control and status ---------------------------------
  input  logic [7:0]        s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [7:0]        s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,

  // ---- AXI4-Stream master: read payload, card -> host ----------------------
  output logic [DATA_W-1:0] m_axis_rd_tdata,
  output logic              m_axis_rd_tvalid,
  input  logic              m_axis_rd_tready,
  output logic              m_axis_rd_tlast, // last beat of the request

  // ---- AXI4-Stream slave: write payload, host -> card ----------------------
  input  logic [DATA_W-1:0] s_axis_wr_tdata,
  input  logic              s_axis_wr_tvalid,
  output logic              s_axis_wr_tready,
  input  logic              s_axis_wr_tlast,

  // ---- interrupt -----------------------------------------------------------
  output logic              irq,            // level, cleared via IRQ_STAT

  // ---- SD card pads --------------------------------------------------------
  output logic              sd_clk,
  inout  wire               sd_cmd,
  inout  wire  [3:0]        sd_dat,
  input  logic              sd_cd           // ACTIVE LOW: 0 = present
`ifdef ULTRA_SD_DEBUG_PORT
  ,
  // Komut merdiveninin gozlem kelimesi. Port yalnizca makro tanimliyken var;
  // ultra_sd_cmd'deki yorum neden gerektigini anlatiyor.
  output logic [63:0]       dbg
`endif
);

  import ultra_sd_pkg::*;

  // ---------------------------------------------------------------------------
  // SYS_CLK_HZ'den turetilen sabitler. Frekans YALNIZCA burada bilinir: alt
  // moduller oranlari parametre olarak alir ve hicbiri Hz varsaymaz (R-CLK-2).
  // Bolme oranlari yukari yuvarlanir, cunku sinirlar UST sinirdir: 400 kHz'i
  // asmak baslatmayi bozar, 50 MHz'i asmak High Speed'i bozar (R-DEG-3).
  // ---------------------------------------------------------------------------
  localparam int CLK_DIV_INIT = (SYS_CLK_HZ + 400_000    - 1) / 400_000;
  localparam int CLK_DIV_DS   = (SYS_CLK_HZ + 25_000_000 - 1) / 25_000_000;
  localparam int CLK_DIV_HS   = (SYS_CLK_HZ + 50_000_000 - 1) / 50_000_000;

  // Kart algilama debounce penceresi: ~1 ms.
  localparam int CD_DEBOUNCE_CYC = SYS_CLK_HZ / 1000;

  // Baslatma fazinda SD saati CLK_DIV_INIT'e sabitli, yani bir saniye bu kadar
  // SD cevrimi eder. ACMD41 yoklama penceresi (R-FUNC-17).
  localparam int SD_HZ_INIT = SYS_CLK_HZ / CLK_DIV_INIT;
  localparam int SD_HZ_HS   = SYS_CLK_HZ / CLK_DIV_HS;

  // Veri beklemeleri SD cevrimi cinsinden ve High Speed oranindan olceklenir:
  // Nac icin spec 100 ms'e kadar izin verir (hazard D-6), programlama
  // mesguliyeti icin 500 ms pay birakiyoruz (Table 7-1: erken vazgecme).
  localparam int NAC_TIMEOUT_CLK  = (NAC_TIMEOUT_CLK_P  != 0) ? NAC_TIMEOUT_CLK_P
                                                              : SD_HZ_HS / 10;
  localparam int PROG_TIMEOUT_CLK = (PROG_TIMEOUT_CLK_P != 0) ? PROG_TIMEOUT_CLK_P
                                                              : SD_HZ_HS / 2;

  // ---------------------------------------------------------------------------
  // Saatler ve resetler
  // ---------------------------------------------------------------------------
  // HARD ve SOFT reset ayri tasinir; AND'lenip tek bir asenkron reset neti
  // olarak dagitilmazlar (gerekce: rtl/rst_sync.sv baslıgı).
  logic sys_rst_n;      // clk alani, hard reset, senkron birakilmis
  logic soft_clr;       // clk alani, SENKRON yazilim clear'i
  logic sd_rst_n;       // sd_clk_core alani, hard reset, senkron birakilmis
  logic sd_soft_clr;    // sd_clk_core alani, SENKRON yazilim clear'i
  logic [CFG_CLK_W-1:0] sd_clk_ratio; // bolme orani -> PHY'daki clk_controller
  logic sd_clk_en;      // DQCE enable
  logic sd_clk_core;    // PHY'da gate'lenmis SD saati -> L1, L2, L3, rampa

  // ---------------------------------------------------------------------------
  // L4 <-> cekirdek: Table 5-1 registerlari
  // ---------------------------------------------------------------------------
  logic [CTRL_W-1:0]    ctrl;        // [0] START [1] ABORT [2] STAT_CLEAR
                                     // [3] SOFT_RESET, tek cevrimlik darbeler
  logic [LBA_W-1:0]     lba;
  logic [BLOCKS_W-1:0]  blocks;
  logic                 xfer_dir;    // XFER[0]: 0 = okuma, 1 = yazma
  logic [CFG_CLK_W-1:0] cfg_clk;
  logic [CFG_PHY_W-1:0] cfg_phy;

  logic [STATUS_W-1:0]  status;
  err_e                 err_code;
  logic [31:0]          stat_data, stat_gap, stat_busy;
  logic [15:0]          stat_retry_crc, stat_retry_cmd;
  logic                 stat_clear_tgl;   // sayaclara silme komutu (cdc.md 9)
  logic [1:0]           irq_set;     // [0] DONE, [1] ERR (sysctl'den)

  // ---------------------------------------------------------------------------
  // system_controller
  // ---------------------------------------------------------------------------
  logic                     card_present;
  logic                     card_change;
  logic                     bus_wide;       // 1 = 4-bit DAT, 0 = 1-bit
  logic                     ramp_done;
  logic                     xfer_go;        // L3'e transfer izni, seviye
  logic                     xfer_launch;    // transfer basladi, tek cevrim

  // ---------------------------------------------------------------------------
  // L2: separate command transport and initialization policy, connected by
  // ultra_sd_protocol. The wrapper selects init/block requests and routes
  // completion to the accepted requester; all modules use sd_clk_core.
  // ---------------------------------------------------------------------------
  logic                   init_busy;
  logic                   init_done;
  logic                   init_err;
  err_e                   init_err_code;
  logic [15:0]            rca;
  logic [31:0]            card_blk;
  speed_e                 speed;
  logic                   bus_4bit;
  logic [CFG_CLK_W-1:0]   init_clk_div;
  logic                   init_dat_start;
  logic [10:0]            init_dat_bytes;

  logic                   cmd_req_ready;
  logic                   cmd_rsp_valid;
  logic                   cmd_rsp_err;
  err_e                   cmd_err_code;
  logic                   cmd_out;
  logic                   cmd_oe;
  logic                   cmd_in;

  // ---------------------------------------------------------------------------
  // L3: blok katmani
  // ---------------------------------------------------------------------------
  logic                   blk_accept;
  logic                   blk_busy;
  logic                   blk_fin;
  logic                   blk_fail;
  err_e                   blk_fail_code;
  logic                   blk_req_valid;
  logic [5:0]             blk_req_index;
  logic [31:0]            blk_req_arg;
  resp_e                  blk_req_resp;
  logic                   blk_req_is_acmd;

  // ---------------------------------------------------------------------------
  // L3 <-> L1: DAT motoru
  // ---------------------------------------------------------------------------
  logic                     dat_start;
  logic                     dat_dir;
  logic [31:0]              tx_data;
  logic                     tx_take;
  logic                     tx_done;
  logic                     tx_status_ok;
  logic                     tx_status_tmo;
  logic [31:0]              rx_data;
  logic                     rx_valid;
  logic                     rx_busy;
  logic                     rx_done;
  logic                     rx_crc_ok;
  logic                     dat_active;
  logic                     card_busy;
  logic                     line_start;
  logic                     line_dir;
  logic [10:0]              line_bytes;

  // Init owns DAT until the card has completed the ladder.  There cannot be a
  // block request before init_done, so this is a priority mux rather than a
  // stateful arbiter.  init_dat_start is a level handshake held through S_DAT.
  assign line_start = init_dat_start | dat_start;
  assign line_dir   = init_dat_start ? 1'b0 : dat_dir;
  assign line_bytes = init_dat_start ? init_dat_bytes : 11'(BLOCK_BYTES);

  // ---------------------------------------------------------------------------
  // L1 <-> L0: DAT hatlari
  // ---------------------------------------------------------------------------
  logic [SD_DATA_LANES-1:0] dat_out;
  logic [SD_DATA_LANES-1:0] dat_oe;
  logic [SD_DATA_LANES-1:0] dat_in;

  // ---------------------------------------------------------------------------
  // L4 <-> L3: payload FIFO'lari (sd_clk tarafi, spekulatif)
  // ---------------------------------------------------------------------------
  logic                   rd_pl_en;
  logic [DATA_W-1:0]      rd_pl_data;
  logic                   rd_pl_commit;
  logic                   rd_pl_rewind;
  logic                   rd_pl_block_room;
  logic                   wr_pl_en;
  logic [DATA_W-1:0]      wr_pl_data;
  logic                   wr_pl_last;
  logic                   wr_pl_commit;
  logic                   wr_pl_rewind;
  logic                   wr_pl_block_ready;

  // ===========================================================================
  // system_controller -- reset, kart algilama, faz FSM'i, saat uretimi
  // ===========================================================================
  /* verilator lint_off PINCONNECTEMPTY */
  system_controller #(
    .CD_DEBOUNCE_CYC (CD_DEBOUNCE_CYC),
    .RAMP_CLOCKS     (74),
    .INIT_CLK_DIV    (CLK_DIV_INIT)
  ) u_sysctl (
    .clk              (clk),
    .rst_n_i          (rst_n),
    .soft_reset_i     (ctrl[CTRL_SOFT_RESET_BIT]),
    .stat_clear_i     (ctrl[CTRL_STAT_CLEAR_BIT]),
    .sd_cd_i          (sd_cd),

    // Oran CFG_CLK'ten gelir: merdiven kendi secimini bu kayda yukler, yazilim
    // da uzerine yazabilir (R-DEG-1). Daha once init_clk_div dogrudan buraya
    // bagliydi ve CFG_CLK hicbir yere gitmiyordu -- bolen yazilimdan
    // degistirilemiyor, R-MEAS-6 karakterizasyon taramasi da tek saatte
    // kosuyordu. RAMP fazinda system_controller yine INIT_CLK_DIV'e zorlar.
    .clk_div_i        (cfg_clk),

    .init_done_i      (init_done),
    .start_i          (ctrl[CTRL_START_BIT]),
    .dir_i            (xfer_dir),
    .abort_i          (ctrl[CTRL_ABORT_BIT]),
    .xfer_done_i      (blk_fin),
    .xfer_err_i       (blk_fail),

    .bus_4bit_i       (bus_4bit),

    .rst_n_o          (sys_rst_n),
    .soft_clr_o       (soft_clr),
    .sd_rst_n_o       (sd_rst_n),
    .sd_soft_clr_o    (sd_soft_clr),
    // Baska saat alani yok: clk ve sd_clk_core'un onaylari sysctl'in kendi
    // icinde. axis_clk ayri bir port olunca o alanin rst_sync onayi buraya
    // baglanacak.
    .soft_ack_ext_i   (1'b1),

    .card_present_o   (card_present),
    .card_change_o    (card_change),

    // Saat kararlari PHY'a gider: oran + gate enable, saatin kendisi degil.
    .sd_clk_ratio_o   (sd_clk_ratio),
    .sd_clk_en_o      (sd_clk_en),

    // Rampa sayimi icin gate'lenmis SD saati
    .sd_clk_i         (sd_clk_core),

    .bus_wide_o       (bus_wide),
    .xfer_go_o        (xfer_go),

    .xfer_launch_o    (xfer_launch),
    .sys_phase_o      (),
    .ramp_done_o      (ramp_done),
    .cfg_start_o      (),

    // Table 5-1: ayri bir modul yok, faz FSM'inin icinde. xfer_done_i /
    // xfer_err_i yukarida zaten bagli -- "fin" ve "fail" onlardir.
    .accept_i         (blk_accept),
    .busy_i           (blk_busy),
    .fail_code_i      (blk_fail_code),
    .card_ready_i     (init_done),
    .speed_i          (speed),
    .init_err_i       (init_err),
    .init_err_code_i  (init_err_code),

    .status_o         (status),
    .err_o            (err_code),
    .irq_set_o        (irq_set),

    // Table 5-2 sayaclarinin tek ortak sinyali: silme komutu.
    .stat_clear_tgl_o (stat_clear_tgl)
  );

  // ===========================================================================
  // L4 -- AXI4-Lite + register dosyasi + AXI4-Stream adaptorleri
  //
  // FIFO'larin SD tarafi sd_clk_core'dur: L3 o saatte kosar (doc/cdc.md 1, 2).
  // Register dosyasi sys_rst_n ile kurulur ve soft clear ALMAZ: soft reset
  // yazilimin konfigurasyonunu silmemeli.
  // ===========================================================================
  ultra_sd_axi_top #(
    .DATA_W         (DATA_W),
    .ADDR_W         (8),
    .RD_FIFO_BLOCKS (RD_FIFO_BLOCKS),
    .WR_FIFO_BLOCKS (WR_FIFO_BLOCKS)
  ) u_axi (
    .clk                  (clk),
    .rst_n                (sys_rst_n),
    .sd_clk               (sd_clk_core),
    .sd_rst_n             (sd_rst_n),
    .sd_soft_clr          (sd_soft_clr),
    .axi_soft_clr         (soft_clr),

    .s_axil_awaddr        (s_axil_awaddr),
    .s_axil_awvalid       (s_axil_awvalid),
    .s_axil_awready       (s_axil_awready),
    .s_axil_wdata         (s_axil_wdata),
    .s_axil_wstrb         (s_axil_wstrb),
    .s_axil_wvalid        (s_axil_wvalid),
    .s_axil_wready        (s_axil_wready),
    .s_axil_bresp         (s_axil_bresp),
    .s_axil_bvalid        (s_axil_bvalid),
    .s_axil_bready        (s_axil_bready),
    .s_axil_araddr        (s_axil_araddr),
    .s_axil_arvalid       (s_axil_arvalid),
    .s_axil_arready       (s_axil_arready),
    .s_axil_rdata         (s_axil_rdata),
    .s_axil_rresp         (s_axil_rresp),
    .s_axil_rvalid        (s_axil_rvalid),
    .s_axil_rready        (s_axil_rready),

    .m_axis_rd_tdata      (m_axis_rd_tdata),
    .m_axis_rd_tvalid     (m_axis_rd_tvalid),
    .m_axis_rd_tready     (m_axis_rd_tready),
    .m_axis_rd_tlast      (m_axis_rd_tlast),

    .s_axis_wr_tdata      (s_axis_wr_tdata),
    .s_axis_wr_tvalid     (s_axis_wr_tvalid),
    .s_axis_wr_tready     (s_axis_wr_tready),
    .s_axis_wr_tlast      (s_axis_wr_tlast),

    .irq                  (irq),

    .CTRL                 (ctrl),
    .LBA                  (lba),
    .BLOCKS               (blocks),
    .XFER                 (xfer_dir),
    .CFG_CLK              (cfg_clk),
    .CFG_CLK_HW           (init_clk_div),
    .CFG_PHY              (cfg_phy),
    .xfer_launch          (xfer_launch),
    .rd_xfer_busy         (),

    .STATUS               (status),
    .ERR                  (err_code),
    .CARD_BLK             (card_blk),
    .STAT_DATA            (stat_data),
    .STAT_GAP             (stat_gap),
    .STAT_BUSY            (stat_busy),
    // STAT_RETRY iki yarim: [31:16] komut denemeleri (L2), [15:0] CRC (L3).
    .STAT_RETRY           ({stat_retry_cmd, stat_retry_crc}),
    // Her uc bit de sysctl'den gelir ve ayni clk alanindadir.
    .IRQ_SET              ({card_change, irq_set}),

    .sd_rd_pl_en          (rd_pl_en),
    .sd_rd_pl_data        (rd_pl_data),
    .sd_rd_pl_commit      (rd_pl_commit),
    .sd_rd_pl_rewind      (rd_pl_rewind),
    .sd_rd_pl_full        (),
    .sd_rd_pl_block_room  (rd_pl_block_room),
    .sd_rd_pl_level       (),

    .sd_wr_pl_en          (wr_pl_en),
    .sd_wr_pl_commit      (wr_pl_commit),
    .sd_wr_pl_rewind      (wr_pl_rewind),
    .sd_wr_pl_data        (wr_pl_data),
    .sd_wr_pl_last        (wr_pl_last),
    .sd_wr_pl_valid       (),
    .sd_wr_pl_level       (),
    .sd_wr_pl_block_ready (wr_pl_block_ready)
  );

  // ===========================================================================
  // L3 -- blok katmani. sd_clk_core alaninda, yani L2 ve L1 ile AYNI saat.
  // ===========================================================================
  ultra_sd_block #(
    .DATA_W           (DATA_W),
    .CRC_RETRIES      (CRC_RETRIES),
    .NAC_TIMEOUT_CLK  (NAC_TIMEOUT_CLK),
    .PROG_TIMEOUT_CLK (PROG_TIMEOUT_CLK)
  ) u_block (
    .clk               (sd_clk_core),
    .rst_n             (sd_rst_n),
    .soft_clr          (sd_soft_clr),

    .go_i              (xfer_go),
    .card_present_i    (card_present),
    .card_ready_i      (init_done),
    .lba_i             (lba),
    .blocks_i          (blocks),
    .dir_i             (xfer_dir),
    .card_blk_i        (card_blk),
    .rca_i             (rca),

    .accept_o          (blk_accept),
    .busy_o            (blk_busy),
    .fin_o             (blk_fin),
    .fail_o            (blk_fail),
    .fail_code_o       (blk_fail_code),
    .stat_clear_tgl_i  (stat_clear_tgl),
    .stat_gap_o        (stat_gap),
    .stat_retry_crc_o  (stat_retry_crc),

    .req_valid_o       (blk_req_valid),
    .req_index_o       (blk_req_index),
    .req_arg_o         (blk_req_arg),
    .req_resp_o        (blk_req_resp),
    .req_is_acmd_o     (blk_req_is_acmd),
    .req_ready_i       (cmd_req_ready),
    .rsp_valid_i       (cmd_rsp_valid),
    .rsp_err_i         (cmd_rsp_err),
    .cmd_err_i         (cmd_err_code),

    .dat_start_o       (dat_start),
    .dat_dir_o         (dat_dir),
    .tx_data_o         (tx_data),
    .tx_take_i         (tx_take),
    .tx_done_i         (tx_done),
    .tx_status_ok_i    (tx_status_ok),
    .tx_status_tmo_i   (tx_status_tmo),
    .rx_data_i         (rx_data),
    .rx_valid_i        (rx_valid),
    .rx_busy_i         (rx_busy),
    .rx_done_i         (rx_done),
    .rx_crc_ok_i       (rx_crc_ok),
    .dat_active_i      (dat_active),
    .card_busy_i       (card_busy),

    .rd_data_o         (rd_pl_data),
    .rd_en_o           (rd_pl_en),
    .rd_commit_o       (rd_pl_commit),
    .rd_rewind_o       (rd_pl_rewind),
    .rd_room_ok_i      (rd_pl_block_room),

    .wr_data_i         (wr_pl_data),
    .wr_last_i         (wr_pl_last),
    .wr_en_o           (wr_pl_en),
    .wr_commit_o       (wr_pl_commit),
    .wr_rewind_o       (wr_pl_rewind),
    .wr_block_ready_i  (wr_pl_block_ready)
  );
  // ===========================================================================
  // L2 -- komut motoru + baslatma merdiveni. Pedlere giden CMD yolu buradan
  // PHY'a tamamdir. Merdiven rampa bittigi anda (ramp_done, seviye) baslar ve
  // hat uzerindeki onceligi modulun kendi icinde cozulur.
  // ===========================================================================
  ultra_sd_protocol #(
    .CMD_RETRIES        (CRC_RETRIES),
    .NCC_GAP_CLK        (NCC_GAP_CLK),
    .CLK_DIV_INIT       (CLK_DIV_INIT),
    .CLK_DIV_DS         (CLK_DIV_DS),
    .CLK_DIV_HS         (CLK_DIV_HS),
    .ACMD41_TIMEOUT_CLK (SD_HZ_INIT)
  ) u_cmd (
    .cmd_clk         (sd_clk_core),
    .rst_n           (sd_rst_n),
    .soft_clr         (sd_soft_clr),

    // L3 istek portu
    .req_valid_i     (blk_req_valid),
    .req_index_i     (blk_req_index),
    .req_arg_i       (blk_req_arg),
    .req_resp_i      (blk_req_resp),
    .req_is_acmd_i   (blk_req_is_acmd),
    .req_ready_o     (cmd_req_ready),

    .rsp_valid_o     (cmd_rsp_valid),
    // The protocol wrapper routes the response payload to u_init.
    .rsp_data_o      (),
    .rsp_crc_ok_o    (),
    .rsp_err_o       (cmd_rsp_err),
    .err_o           (cmd_err_code),

    // STATUS.CARD_READY init_done'dan gelir (Appendix B); bu cikis son R1'in
    // READY_FOR_DATA bitidir ve su an tuketicisi yok.
    .card_ready_o    (),

    // Baslatma merdiveni
    .card_present_i  (card_present),
    .ramp_done_i     (ramp_done),

    // Table 7-1 geri cekilmeleri merdivenin karar anlarina gider: genislik ve
    // hiz kartla anlasma oldugu icin tek tarafli uygulanamaz (ultra_sd_cmd'in
    // port yorumuna bak). Yazilim CFG_PHY'yi yazip SOFT_RESET verir.
    .force_1bit_i    (cfg_phy[CFG_PHY_FORCE_1BIT]),
    .force_ds_i      (cfg_phy[CFG_PHY_FORCE_DS]),
    .init_busy_o     (init_busy),
    .init_done_o     (init_done),
    .init_err_o      (init_err),
    .init_err_code_o (init_err_code),
`ifdef ULTRA_SD_DEBUG_PORT
    .dbg_o           (dbg),
`endif

    .dat_rd_start_o  (init_dat_start),
    .dat_rd_bytes_o  (init_dat_bytes),
    .dat_rd_data_i   (rx_data),
    .dat_rd_valid_i  (rx_valid),
    .dat_rd_busy_i   (rx_busy),
    .dat_rd_crc_ok_i (rx_crc_ok),

    .rca_o           (rca),
    .card_blk_o      (card_blk),
    .speed_o         (speed),
    .bus_4bit_o      (bus_4bit),
    .clk_div_o       (init_clk_div),

    .stat_clear_tgl_i (stat_clear_tgl),
    .stat_retry_cmd_o (stat_retry_cmd),

    .cmd_out_o       (cmd_out),
    .cmd_oe_o        (cmd_oe),
    .cmd_in_i        (cmd_in)
  );

  // ===========================================================================
  // L1 -- DAT cerceveleme. SD saati alaninda; bus_wide_i sistem saatinden
  // gelen tek-bit kontroldur ve senkronizasyonu modulun ICINDE yapilir
  // (doc/cdc.md 6). dir_i / start_i artik AYNI saatten gelir (L3 de
  // sd_clk_core'da kosar), yani o ikisi crossing degil.
  // ===========================================================================
  ultra_sd_line u_line (
    .line_clk        (sd_clk_core),
    .rst_n           (sd_rst_n),
    .soft_clr        (sd_soft_clr),

    .bus_wide_i      (bus_wide),

    .stat_clear_tgl_i (stat_clear_tgl),
    .stat_data_o      (stat_data),
    .stat_busy_o      (stat_busy),
    .dir_i           (line_dir),
    .start_i         (line_start),
    .xfer_bytes_i    (line_bytes),

    .tx_data_i       (tx_data),
    .tx_take_o       (tx_take),
    .tx_busy_o       (),
    .tx_done_o       (tx_done),
    .tx_status_o     (),
    .tx_status_ok_o  (tx_status_ok),
    .tx_status_tmo_o (tx_status_tmo),

    .rx_data_o       (rx_data),
    .rx_valid_o      (rx_valid),
    .rx_busy_o       (rx_busy),
    .rx_done_o       (rx_done),
    .rx_crc_ok_o     (rx_crc_ok),

    .dat_active_o    (dat_active),
    .card_busy_o     (card_busy),

    .dat_out_o       (dat_out),
    .dat_oe_o        (dat_oe),
    .dat_in_i        (dat_in)
  );

  // ===========================================================================
  // L0 -- pedler. Satici primitifi bulunan TEK modul (R-ARCH-2); inout portlar
  // dogrudan buraya gider, yolda hicbir sey yok.
  // ===========================================================================
  ultra_sd_phy_gowin u_phy (
    .clk            (clk),
    // PHY clk alaninda: hard reset sys_rst_n. Icindeki clk_controller
    // (bolucu) bu yuzden soft reset'ten ETKILENMEZ -- senkron clear'in
    // uygulanabilmesi icin SD saatinin kosmaya devam etmesi gerekiyor.
    .rst_n          (sys_rst_n),
    .soft_clr       (soft_clr),

    .cfg_phy_i      (cfg_phy),

    // Bolme orani girer, gate'lenmis TEK saat cikar. Bolucu (clk_controller)
    // ve gate (DQCE) bu modulun icinde; ped de cekirdek de ayni agdan surulur.
    .clk_div_i      (sd_clk_ratio),
    .sd_clk_en_i    (sd_clk_en),
    .sd_clk_o       (sd_clk_core),

    .cmd_out_i      (cmd_out),
    .cmd_oe_i       (cmd_oe),
    .cmd_in_o       (cmd_in),

    .dat_out_i      (dat_out),
    .dat_oe_i       (dat_oe),
    .dat_in_o       (dat_in),

    .sd_clk         (sd_clk),
    .sd_cmd         (sd_cmd),
    .sd_dat         (sd_dat)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // Henuz tuketicisi olmayan, ama sozlesmede duran sinyaller. init_busy
  // STATUS'ta BUSY ile birlesmiyor, cunku Table 5-1 BUSY'yi transfere bagliyor.
  /* verilator lint_off UNUSED */
  logic unused_ok;
  assign unused_ok = ^{init_busy};
  /* verilator lint_on UNUSED */

endmodule

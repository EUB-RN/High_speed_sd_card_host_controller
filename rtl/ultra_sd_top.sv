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
//     u_cmd     ultra_sd_cmd        L2: komut gonderme, yanit cozme VE
//                                   baslatma merdiveni (tek modul: ikisi
//                                   ayriyken istekleri burada mux'lanıyordu)
//     u_line    ultra_sd_line       L1: DAT cerceveleme
//     u_phy     ultra_sd_phy_gowin  L0: pedler, uc-durum, ornekleme fazi
//
//   ---------------------------------------------------------------------------
//   SAAT ALANLARI
//   ---------------------------------------------------------------------------
//   clk       : L4 (AXI), system_controller, PHY'nin kontrol mantigi
//   cmd_clk   : L2 (u_cmd) ve L3 (u_block)
//   line_clk  : L1 (u_line)
//   Saat yolu iki parcaya bolunmustur:
//     ultra_sd_phy_gowin        BOLER + GATE'LER -> clk_controller, DQCE, DCS
//     faz FSM'i (system_controller)  KARAR       -> oran + enable + secim biti
//   Bolunmus (ham) saat artik hicbir modul siniri gecmiyor: sysctl'den PHY'a
//   yalnizca bir SAYI (oran) ve bir enable gider, PHY'dan geri gate'lenmis
//   saatler tuketicilere ve rampa sayacina doner.
//   cmd_clk ile line_clk ayni clk_controller'dan, ayni bolme oranindan cikar,
//   yani faz kilitlidir (doc/cdc.md): aralarindaki yollar crossing sayilmaz.
//   clk <-> cmd_clk/line_clk gecisleri doc/cdc.md 1,2,6 numarali satirlardir ve
//   tamami tuketici modulun ICINDE cozulur; burada senkronizer YOKTUR.
//
//   ---------------------------------------------------------------------------
//   TABLE 5-2 SAYACLARI
//   ---------------------------------------------------------------------------
//   Ayri bir istatistik modulu YOK. Her sayac olayini URETEN FSM'in icinde ve
//   o FSM'in saatinde durur (R-IF-11), cunku olay orada bir case kolu:
//     STAT_DATA, STAT_BUSY       u_line   (line_clk)
//     STAT_GAP, STAT_RETRY[15:0] u_block  (cmd_clk)
//     STAT_RETRY[31:16]          u_cmd    (cmd_clk)
//   Bu dosyanin payi yalnizca STAT_CLEAR toggle'ini ucune dagitmak ve iki
//   yeniden deneme yarisini tek registera birlestirmek.
//
// -----------------------------------------------------------------------------
module ultra_sd_top #(
  parameter int SYS_CLK_HZ     = 100_000_000, // supplied by harness
  parameter int DATA_W         = 32,          // AXIS payload width
  parameter int RD_FIFO_BLOCKS = 2,
  parameter int WR_FIFO_BLOCKS = 2,
  parameter int CRC_RETRIES    = 3
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
  localparam int NAC_TIMEOUT_CLK  = SD_HZ_HS / 10;
  localparam int PROG_TIMEOUT_CLK = SD_HZ_HS / 2;

  // ---------------------------------------------------------------------------
  // Saatler ve resetler
  // ---------------------------------------------------------------------------
  logic sys_rst_n;      // dis reset, senkron birakilmis
  logic core_rst_n;     // dis reset + CTRL.SOFT_RESET
  logic [CFG_CLK_W-1:0] sd_clk_ratio; // bolme orani -> PHY'daki clk_controller
  logic cmd_clk_en;     // DQCE enable, CMD kanali
  logic line_clk_en;    // DQCE enable, LINE kanali
  logic pad_line_sel;   // DCS secimi: 1 = ped line_clk'ten surulur
  logic cmd_clk;        // PHY'da gate'lenmis CMD saati  -> L2, L3, rampa sayaci
  logic line_clk;       // PHY'da gate'lenmis LINE saati -> L1

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

  // ---------------------------------------------------------------------------
  // L2: komut motoru + baslatma merdiveni (tek modul)
  //
  // Eskiden burada bir arbitrasyon katmani vardi: init ile blok isteklerini
  // birlestiren 42 bitlik 2:1 mux ve hazir/yanit yonlendirmesi. Ikisi tek
  // modul olunca o katman tamamen kalkti -- ve birlikte init_req_*, arb_req_*,
  // cmd_rsp_data ile rca geri besleme dongusu de.
  // ---------------------------------------------------------------------------
  logic                   init_busy;
  logic                   init_done;
  logic                   init_err;
  err_e                   init_err_code;
  logic [15:0]            rca;
  logic [31:0]            card_blk;
  logic                   block_addr;
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

    // Oran init merdiveninden gelir; yazilim CFG_CLK ile ustune yazabilir
    // (R-DEG-1), bu secim ultra_sd_init icinde cozulur.
    .clk_div_i        (init_clk_div),

    .init_done_i      (init_done),
    .start_i          (ctrl[CTRL_START_BIT]),
    .dir_i            (xfer_dir),
    .abort_i          (ctrl[CTRL_ABORT_BIT]),
    .xfer_done_i      (blk_fin),
    .xfer_err_i       (blk_fail),

    .bus_4bit_i       (bus_4bit),
    .force_1bit_i     (cfg_phy[CFG_PHY_FORCE_1BIT]),

    .rst_n_o          (sys_rst_n),
    .core_rst_n_o     (core_rst_n),

    .card_present_o   (card_present),
    .card_change_o    (card_change),

    // Saat kararlari PHY'a gider: oran + gate enable, saatin kendisi degil.
    .sd_clk_ratio_o   (sd_clk_ratio),
    .sd_clk_en_o      (cmd_clk_en),

    // Rampa sayimi icin gate'lenmis SD saati
    .cmd_clk_i        (cmd_clk),

    .bus_wide_o       (bus_wide),
    .xfer_go_o        (xfer_go),

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

  assign line_clk_en  = cmd_clk_en;
  assign pad_line_sel = 1'b0;

  // ===========================================================================
  // L4 -- AXI4-Lite + register dosyasi + AXI4-Stream adaptorleri
  //
  // sd_clk tarafi cmd_clk'tir: L3 o saatte kosar, dolayisiyla async FIFO'larin
  // SD tarafi da orada olmak zorunda (doc/cdc.md 1 ve 2).
  // Register dosyasi sys_rst_n ile kurulur, core_rst_n ile DEGIL: soft reset
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
    .sd_clk               (cmd_clk),
    .sd_rst_n             (core_rst_n),

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
    .CFG_PHY              (cfg_phy),
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
  // Transfer argumanlarinin on-denetimi -- BILEREK clk alaninda, L3'te degil.
  //
  // Denetlenen uc sey: lba + blocks kartin kapasitesini asiyor mu (R-FUNC-4),
  // blocks sifir mi, blocks birden buyuk mu (cok bloklu mu). Ucu de eskiden
  // L3'un icinde, go_rise kolunun ortasinda kombinasyonel duruyordu ve
  // asagidaki koniyi uretiyordu:
  //
  //   u_axi/u_reg/BLOCKS -> 33 bit toplama -> card_blk ile karsilastirma ->
  //   start_err -> start_bad -> fail_o -> u_block/step_q, post_q ve
  //   u_sysctl/err_q, phase_q'nun CE'leri
  //
  // 15-16 mantik seviyesi. clk'in Fmax'ini asagi ceken yol buydu ve yukun
  // bindigi taraf da burasi: BLOCKS ile LBA zaten bu alanda, u_reg'de
  // kilitleniyor. O yuzden boru hatti da burada -- L3'e tasinirsa flop
  // cmd_clk alanina duser ve yuk sadece yer degistirir.
  //
  // Iki asama, cunku toplama ile karsilastirma iki ayri tasima zinciri:
  //   asama 1: lba + blocks
  //   asama 2: card_blk ile karsilastir
  // L3'e giden uc bit, orada tek mux ile kullanilir.
  //
  // Gecikme guvenli: argumanlar go'ya gore quasi-statiktir. LBA ve BLOCKS
  // CTRL.START yazisiyla ayni cevrimde kilitlenir, card_blk merdivenden beri
  // sabittir; xfer_go ise en erken bir clk sonra kalkar ve L3'te iki flopluk
  // senkronizasyon + kenar yakalamadan gecer, yani go_rise bu iki asamadan
  // sonradir.
  // ===========================================================================
  logic [32:0] last_blk_q;
  logic        start_range_bad;
  logic        start_blocks_zero;
  logic        start_multi;

  always_ff @(posedge clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      last_blk_q        <= '0;
      start_range_bad   <= 1'b0;
      start_blocks_zero <= 1'b1;
      start_multi       <= 1'b0;
    end else begin
      last_blk_q        <= {1'b0, lba} + {1'b0, 32'(blocks)};
      start_range_bad   <= (last_blk_q > {1'b0, card_blk});
      start_blocks_zero <= (blocks == '0);
      start_multi       <= (blocks > BLOCKS_W'(1));
    end
  end

  // ===========================================================================
  // L3 -- blok katmani. cmd_clk alaninda: L2 ile ayni saat, L1 ile faz kilitli.
  // ===========================================================================
  ultra_sd_block #(
    .DATA_W           (DATA_W),
    .CRC_RETRIES      (CRC_RETRIES),
    .NAC_TIMEOUT_CLK  (NAC_TIMEOUT_CLK),
    .PROG_TIMEOUT_CLK (PROG_TIMEOUT_CLK)
  ) u_block (
    .clk               (cmd_clk),
    .rst_n             (core_rst_n),

    .go_i              (xfer_go),
    .card_present_i    (card_present),
    .card_ready_i      (init_done),
    .lba_i             (lba),
    .blocks_i          (blocks),
    .dir_i             (xfer_dir),
    .start_range_bad_i   (start_range_bad),
    .start_blocks_zero_i (start_blocks_zero),
    .start_multi_i       (start_multi),
    .block_addr_i      (block_addr),
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
  ultra_sd_cmd #(
    .CMD_RETRIES        (CRC_RETRIES),
    .CLK_DIV_INIT       (CLK_DIV_INIT),
    .CLK_DIV_DS         (CLK_DIV_DS),
    .CLK_DIV_HS         (CLK_DIV_HS),
    .ACMD41_TIMEOUT_CLK (SD_HZ_INIT)
  ) u_cmd (
    .cmd_clk         (cmd_clk),
    .rst_n           (core_rst_n),

    // L3 istek portu
    .req_valid_i     (blk_req_valid),
    .req_index_i     (blk_req_index),
    .req_arg_i       (blk_req_arg),
    .req_resp_i      (blk_req_resp),
    .req_is_acmd_i   (blk_req_is_acmd),
    .req_ready_o     (cmd_req_ready),

    .rsp_valid_o     (cmd_rsp_valid),
    // Yanit yuku yalnizca merdivenin isine yariyordu, o da artik modulun
    // icinde; burada gozlem icin acikta.
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
    .init_busy_o     (init_busy),
    .init_done_o     (init_done),
    .init_err_o      (init_err),
    .init_err_code_o (init_err_code),

    .dat_rd_start_o  (init_dat_start),
    .dat_rd_bytes_o  (init_dat_bytes),
    .dat_rd_data_i   (rx_data),
    .dat_rd_valid_i  (rx_valid),
    .dat_rd_busy_i   (rx_busy),
    .dat_rd_crc_ok_i (rx_crc_ok),

    .rca_o           (rca),
    .card_blk_o      (card_blk),
    .block_addr_o    (block_addr),
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
  // L1 -- DAT cerceveleme. line_clk alaninda; bus_wide_i ve start_i sistem /
  // SD saatinden gelen tek-bit kontrollerdir ve senkronizasyonu modulun
  // ICINDE yapilir (doc/cdc.md 6).
  // ===========================================================================
  ultra_sd_line u_line (
    .line_clk        (line_clk),
    .rst_n           (core_rst_n),

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
    .rst_n          (core_rst_n),

    .cfg_phy_i      (cfg_phy),

    // Bolme orani girer, gate'lenmis saatler cikar. Bolucu (clk_controller),
    // ped mux'u (DCS) ve kanal gate'leri (DQCE) bu modulun icinde.
    .clk_div_i      (sd_clk_ratio),
    .cmd_clk_en_i   (cmd_clk_en),
    .line_clk_en_i  (line_clk_en),
    .pad_line_sel_i (pad_line_sel),
    .cmd_clk_o      (cmd_clk),
    .line_clk_o     (line_clk),

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

  // Henuz tuketicisi olmayan, ama sozlesmede duran sinyaller. CFG_CLK yazilim
  // override'i ultra_sd_init icinde cozulecek (R-DEG-1); init_busy STATUS'ta
  // BUSY ile birlesmiyor, cunku Table 5-1 BUSY'yi transfere bagliyor.
  /* verilator lint_off UNUSED */
  logic unused_ok;
  assign unused_ok = ^{cfg_clk, init_busy, cfg_phy[CFG_PHY_FORCE_DS]};
  /* verilator lint_on UNUSED */

endmodule

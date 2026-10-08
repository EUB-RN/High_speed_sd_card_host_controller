// -----------------------------------------------------------------------------
// ultra_sd_pkg
//   Purpose      : Shared types, SD command opcodes, register offsets, error
//                  codes and field widths for the whole core. No logic lives
//                  here, so that R-ARCH-4.4 ("no magic numbers in the RTL") can
//                  be satisfied by naming every constant exactly once.
//   Clock domain : none (declarations only)
//   Reset scheme : none (declarations only)
//   Implements   : Spec Table 5-1 (register map), Table 5-3 (error codes),
//                  Appendix A Table A-1 (command subset)
// -----------------------------------------------------------------------------
package ultra_sd_pkg;

  // ---- AXI4-Lite register offsets (Packed 32-bit Architecture) ------------
  localparam logic [7:0] REG_VERSION     = 8'h00; // RO: [31:16] Magic, [15:8] Major, [7:0] Minor
  localparam logic [7:0] REG_CTRL_STATUS = 8'h04; // RW: W: CTRL / IRQ_EN / W1C IRQ_STAT
                                                  //     R: STATUS / ERR / IRQ_STAT / IRQ_EN / irq
  localparam logic [7:0] REG_LBA         = 8'h08; // RW: [31:0] LBA sector address
  localparam logic [7:0] REG_XFER_CFG    = 8'h0C; // RW: [23:0] BLOCKS, [31] DIR (0:read, 1:write)
  localparam logic [7:0] REG_HW_CFG      = 8'h10; // RW: [7:0] CFG_CLK, [13:8] CFG_PHY
  localparam logic [7:0] REG_CARD_BLK    = 8'h14; // RO: [31:0] Card capacity in blocks
  localparam logic [7:0] REG_STAT_DATA   = 8'h18; // RO: [31:0] SD clk data counter
  localparam logic [7:0] REG_STAT_GAP    = 8'h1C; // RO: [31:0] SD clk gap counter
  localparam logic [7:0] REG_STAT_BUSY   = 8'h20; // RO: [31:0] SD clk busy counter
  localparam logic [7:0] REG_STAT_RETRY  = 8'h24; // RO: [31:16] CMD retry, [15:0] CRC retry

  // Backward compatibility aliases
  localparam logic [7:0] REG_CTRL        = REG_CTRL_STATUS;
  localparam logic [7:0] REG_STATUS      = REG_CTRL_STATUS;
  localparam logic [7:0] REG_ERR         = REG_CTRL_STATUS;
  localparam logic [7:0] REG_BLOCKS      = REG_XFER_CFG;
  localparam logic [7:0] REG_XFER        = REG_XFER_CFG;
  localparam logic [7:0] REG_CFG_CLK     = REG_HW_CFG;
  localparam logic [7:0] REG_CFG_PHY     = REG_HW_CFG;
  localparam logic [7:0] REG_IRQ_EN      = REG_CTRL_STATUS;
  localparam logic [7:0] REG_IRQ_STAT    = REG_CTRL_STATUS;

  localparam logic [15:0] VERSION_MAGIC = 16'h5344;

  // ---- Error codes, Table 5-3 (exact numeric values are normative) ---------
  typedef enum logic [7:0] {
    ERR_OK            = 8'h00,
    ERR_CMD_TIMEOUT   = 8'h01,
    ERR_CMD_CRC       = 8'h02,
    ERR_CMD_STATUS    = 8'h03,
    ERR_DAT_TIMEOUT   = 8'h04,
    ERR_DAT_CRC       = 8'h05,
    ERR_WR_CRC_TOKEN  = 8'h06,
    ERR_NO_CARD       = 8'h07,
    ERR_INIT          = 8'h08,
    ERR_UNSUPPORTED   = 8'h09,
    ERR_RANGE         = 8'h0A,
    ERR_CARD_STATE    = 8'h0B,
    ERR_PROTOCOL      = 8'h0C
  } err_e;

  // ---- Command subset, Appendix A Table A-1 -------------------------------
  typedef enum logic [5:0] {
    CMD0_GO_IDLE_STATE        = 6'd0,
    CMD2_ALL_SEND_CID         = 6'd2,
    CMD3_SEND_RELATIVE_ADDR   = 6'd3,
    CMD6_SWITCH_FUNC          = 6'd6,
    CMD7_SELECT_CARD          = 6'd7,
    CMD8_SEND_IF_COND         = 6'd8,
    CMD9_SEND_CSD             = 6'd9,
    CMD12_STOP_TRANSMISSION   = 6'd12,
    CMD13_SEND_STATUS         = 6'd13,
    CMD17_READ_SINGLE_BLOCK   = 6'd17,
    CMD18_READ_MULTIPLE_BLOCK = 6'd18,
    CMD24_WRITE_BLOCK         = 6'd24,
    CMD25_WRITE_MULTIPLE_BLK  = 6'd25,
    CMD55_APP_CMD             = 6'd55
  } cmd_e;

  // ACMDs, issued after CMD55
  localparam logic [5:0] ACMD6_SET_BUS_WIDTH          = 6'd6;
  localparam logic [5:0] ACMD23_SET_WR_BLK_ERASE_CNT  = 6'd23;
  localparam logic [5:0] ACMD41_SD_SEND_OP_COND       = 6'd41;
  localparam logic [5:0] ACMD51_SEND_SCR              = 6'd51;

  // ---- Response formats, Table A-2 ----------------------------------------
  typedef enum logic [2:0] {
    RESP_NONE, RESP_R1, RESP_R1B, RESP_R2, RESP_R3, RESP_R6, RESP_R7
  } resp_e;

  localparam int RESP_SHORT_BITS = 48;
  localparam int RESP_LONG_BITS  = 136; // R2 only, hazard D-4

  // ---- CRC polynomials and geometry, Table A-3 -----------------------------
  localparam int CRC7_W  = 7;
  localparam int CRC16_W = 16;

  localparam logic [CRC7_W-1:0]  CRC7_POLY  = 7'h09;    // x^7 + x^3 + 1
  localparam logic [CRC16_W-1:0] CRC16_POLY = 16'h1021; // x^16 + x^12 + x^5 + 1

  localparam logic [CRC7_W-1:0]  CRC7_INIT  = {CRC7_W{1'b0}};
  localparam logic [CRC16_W-1:0] CRC16_INIT = {CRC16_W{1'b0}};

  // CRC7 covers the 40 bits from the start bit to the end of the argument.
  localparam int CMD_CRC7_BITS = 40;

  // ---- Register field positions, Table 5-1 ---------------------------------
  // These exist so that a producer packing STATUS, or a consumer unpacking
  // CTRL, never writes a bare bit number (Section 4.4 forbids magic numbers).

  localparam int CTRL_W               = 4;
  localparam int CTRL_START_BIT       = 0;
  localparam int CTRL_ABORT_BIT       = 1;
  localparam int CTRL_STAT_CLEAR_BIT  = 2;
  localparam int CTRL_SOFT_RESET_BIT  = 3;

  localparam int STATUS_W             = 8;
  localparam int STATUS_BUSY_BIT      = 0;
  localparam int STATUS_DONE_BIT      = 1;
  localparam int STATUS_CARD_PRES_BIT = 2;
  localparam int STATUS_CARD_RDY_BIT  = 3;
  localparam int STATUS_SPEED_LSB     = 4; // 2 bits, speed_e
  localparam int STATUS_BUS_WIDTH_LSB = 6; // 2 bits, 0 = 1-bit

  localparam int CFG_CLK_W            = 8;

  localparam int CFG_PHY_W            = 6;
  localparam int CFG_PHY_PHASE_LSB    = 0; // 4 bits
  localparam int CFG_PHY_PHASE_W      = 4;
  localparam int CFG_PHY_FORCE_1BIT   = 4;
  localparam int CFG_PHY_FORCE_DS     = 5;

  localparam int IRQ_W                = 3;
  localparam int IRQ_DONE_BIT         = 0;
  localparam int IRQ_ERR_BIT          = 1;
  localparam int IRQ_CARD_CHANGE_BIT  = 2;

  localparam int RETRY_CRC_LSB        = 0;  // STAT_RETRY[15:0]
  localparam int RETRY_CMD_LSB        = 16; // STAT_RETRY[31:16]

  localparam int LBA_W                = 32;
  localparam int BLOCKS_W             = 24;

  // ---- Field positions in packed registers ---------------------------------
  localparam int STATUS_LSB           = 0;
  localparam int ERR_LSB              = 8;
  localparam int IRQ_STAT_LSB         = 16;
  localparam int IRQ_EN_LSB           = 24;
  localparam int IRQ_PIN_BIT          = 31;
  localparam int XFER_DIR_BIT         = 31;
  localparam int CFG_CLK_LSB          = 0;
  localparam int CFG_PHY_LSB          = 8;

  // ---- Bus / block geometry ------------------------------------------------
  localparam int BLOCK_BYTES    = 512;
  localparam int SD_DATA_LANES  = 4;   // DAT0..DAT3, one CRC16 each

  typedef enum logic [1:0] {
    SPEED_INIT = 2'd0, // <= 400 kHz
    SPEED_DS   = 2'd1, // 25 MHz Default Speed
    SPEED_HS   = 2'd2  // 50 MHz High Speed
  } speed_e;

  // ---- Sistem fazlari, system_controller FSM'i -----------------------------
  // Cekirdegin kabaca hangi asamada oldugunu tek yerde adlandirir. Baslatma
  // sirasi sabittir: reset -> kart algilama -> 74-clock rampa -> konfigurasyon.
  // SYS_CONFIG ayni zamanda transferler arasindaki "ev" fazidir: veri fazlari
  // oraya gider ve oraya doner.
  typedef enum logic [2:0] {
    SYS_RESET       = 3'd0, // reset (dis ya da soft) etkin / yeni birakildi
    SYS_CARD_DETECT = 3'd1, // debounce edilmis kart varligini bekle
    SYS_RAMP        = 3'd2, // ilk komuttan once >=74 SD saat kenari
    SYS_CONFIG      = 3'd3, // init merdiveni; bittikten sonra bosta bekleme
    SYS_READ        = 3'd4, // veri okuma transferi surmekte (XFER.DIR = 0)
    SYS_WRITE       = 3'd5  // veri yazma transferi surmekte (XFER.DIR = 1)
  } sys_phase_e;

endpackage

// -----------------------------------------------------------------------------
// ultra_sd_block
//   Purpose      : L3. Bir AXI istegini (LBA + blok sayisi + yon) karta
//                  gidecek komut dizisine ve DAT uzerindeki blok akisina
//                  cevirir. Sahip oldugu isler: LBA aritmetigi, blok sayimi,
//                  CMD18/CMD25 akisi, geri basinc, blok basina CRC yeniden
//                  deneme ve Table 5-2 sayaclari. Icinde satici primitifi,
//                  ham bit kaydirma ve AXI el sikismasi YOKTUR (Table 4-1).
//
//   ---------------------------------------------------------------------------
//   ISTEK: SEVIYE, DARBE DEGIL
//   ---------------------------------------------------------------------------
//   Bu modul bolunmus SD saatinde kosar, CTRL darbeleri ise sistem saatinde
//   tek cevrimlik: bolme orani 2..255 oldugu icin bir darbe burada tamamen
//   kaybolurdu. O yuzden baslatma/bitirme sinyali system_controller'in faz
//   seviyesidir (xfer_go_o):
//     yukselen kenar -> transferi basla (CTRL.START, init_done suzgecinden
//                       gecmis)
//     dusen  kenar  -> birak (CTRL.ABORT, kart cikarildi, ya da bizim done'
//                       umuz fazi eve dondurdu)
//   Dusen kenar DONE/ERROR adimlarinda yok sayilir: oradaki dusus bizim
//   bitirdigimizin sonucudur, yeni bir abort degil (R-IF-4: her START icin tam
//   olarak bir tamamlanma).
//
//   ---------------------------------------------------------------------------
//   OKUMA: TEK CMD18, SIFIR BALONCUK, SPEKULATIF FIFO
//   ---------------------------------------------------------------------------
//   Cok bloklu istek TEK bir CMD18 ile kosar (R-FUNC-8); blok basina CMD17
//   verimi %60'a civilar. L1'in start_i'si transfer boyunca YUKARIDA kalir:
//   L1 bir blogu bitirip IDLE'a dondugunde seviyeyi hala yukarida gorur ve bir
//   sonraki blogu kendiliginden silahlar, yani bloklar arasina bizim
//   ekledigimiz bir boslukta yok (metrik L4, <=4 cevrim).
//
//   Bunun bedeli: "bir sonraki blogu BASLATMA" karari gec kalir. L1'in giris
//   senkronizeri iki flop oldugu icin start'i indirdigimizde icerideki kopya
//   hala yukaridadir ve bir blok daha baslayabilir. Cozum iptal etmek degil,
//   ISTEMEDIGIMIZ BLOGU YOK SAYMAK:
//
//     * Okuma yuku AXI FIFO'suna YAZILIR ama FIFO'nun YAYINLANMIS yazma
//       isaretcisi blogun CRC16'si dogrulanana kadar ilerlemez
//       (async_fifo.wr_commit). CRC tutmazsa rd_rewind blogu yok eder:
//       host hatali tek bir beat bile gormez.
//     * Fazladan gelen ya da yarim kalan blok da ayni sekilde geri sarilir --
//       CMD12'den sonra bir blogun yolda olmasi normaldir (hazard D-13).
//
//   Geri basinc (R-IF-7) ayni mekanizmaya yaslanir. Kart CMD18 akisini durdura
//   bilmez; durdurmak icin CMD12 gerekir. Bu yuzden: FIFO'da bir blokluk yer
//   kalmadiginda akis CMD12 ile kapatilir, host boslattiginda kalinan LBA'dan
//   yeni bir CMD18 ile devam edilir. Host ne kadar yavas olursa olsun veri
//   kaybi ya da yanlis CRC raporu olmaz; yalnizca verim duser.
//
//   NEDEN BLOK TAMPONU YOK. Blogu once tampona alip CRC'den sonra FIFO'ya
//   bosaltmak akla yakin durur ama metrik L2'yi (son yuk biti -> son AXI beat
//   <=16 SD cevrimi) bozar: son blogun 128 kelimesini bosaltmak 128 cevrim
//   surer. Spekulatif isaretci ayni korumayi tek cevrimde verir -- yayinlama
//   bir isaretci sicramasidir.
//
//   ---------------------------------------------------------------------------
//   YAZMA: ACMD23 + CMD25, BLOK BASINA SILAHLANMA
//   ---------------------------------------------------------------------------
//   Cok bloklu yazma ACMD23 ile blok sayisini bildirip CMD25 ile kosar
//   (R-FUNC-11). Okumanin tersine her blok TEK TEK silahlanir, cunku bir bloga
//   baslamanin sarti onun tamaminin FIFO'da hazir olmasi: karti blogun
//   ortasinda bekletemeyiz (R-IF-8).
//
//   Her bloktan sonra kart DAT0 uzerinde 5 bitlik CRC durum token'i verir
//   (R-FUNC-13). Olumsuz token blogu gecersiz kilar: yazma FIFO'sunun OKUMA
//   tarafi geri sarilir (rd_rewind), CMD12 + CMD13 ile toparlanilir ve ayni
//   LBA'dan yeni bir CMD25 acilir. Token iyi ise blok islenir (rd_commit) ve
//   kartin programlama mesguliyeti beklenir -- sure STAT_BUSY'ye yazilir ve
//   mesguliyet kalkar kalkmaz bir sonraki blok sunulur (R-FUNC-12).
//
//   ---------------------------------------------------------------------------
//   HATA TOPARLAMA
//   ---------------------------------------------------------------------------
//   Hicbir hata yeniden baslatma gerektirmez (R-FUNC-16, hazard D-12): akis
//   CMD12 ile kapatilir, CMD13 ile kartin durumu okunup yapiskan hata bitleri
//   temizlenir ve ayni istege kalinan yerden devam edilir. CRC16 hatalari
//   CRC_RETRIES kez denenir ve STAT_RETRY[15:0]'ya islenir (R-FUNC-15).
//   Her bekleme sinirli ve isimlendirilmis bir parametreden gelir (R-FUNC-17).
//
//   ---------------------------------------------------------------------------
//   SONUC VE SAYACLAR BURADA DEGIL
//   ---------------------------------------------------------------------------
//   STATUS / ERR / IRQ_SET ve Table 5-2 sayaclarinin sahibi ultra_sd_stat;
//   bu modul yalnizca OLAY bildirir (accept / busy / fin / fail + kod, bosluk
//   hucresi, blok tekrari). Gerekce iki tane: bir, kaydi paketleyen tarafin
//   tek olmasi gerekiyor ve kaynaklar tasarima dagilmis durumda; iki, bu modul
//   zaten R-ARCH-3'un 400 satirina dayaniyor ve sayaclar ayri bir dosyada
//   dogru yerde duruyor.
//
//   Clock domain : clk = cmd_clk, bolunmus SD saati. L1 line_clk'te kosar;
//                  iki saat ayni boluculden ayni orandan cikar, faz
//                  kilitlidir, bu yuzden crossing degildir (doc/cdc.md).
//                  go_i / stat_clear_tgl_i / card_present_i sistem saatindeki
//                  tek-bit kontrollerdir ve burada iki flop ile ornekleniyor.
//   Reset scheme : rst_n, asenkron assert / senkron deassert (R-CLK-1)
//   Implements   : R-IF-3, R-IF-4, R-IF-6, R-IF-7, R-IF-8, R-IF-9, R-IF-11,
//                  R-FUNC-4, R-FUNC-8, R-FUNC-10, R-FUNC-11, R-FUNC-12,
//                  R-FUNC-13, R-FUNC-15, R-FUNC-16, R-FUNC-17
// -----------------------------------------------------------------------------
// import
module ultra_sd_block #(
  // L1'in kelime genisligi 32 bit sabittir; bu parametre AXI tarafiyla ayni
  // kalmak icin var ve 32'den farkli bir deger desteklenmez.
  parameter int DATA_W = 32,
  // R-FUNC-15: bir blok CRC16 yuzunden kac kez tekrarlanir.
  parameter int CRC_RETRIES = 3,
  // R-FUNC-17 / hazard D-6: Nac icin spec 100 ms'e kadar izin veriyor. Birim
  // SD saat cevrimi; ustteki wrapper SYS_CLK_HZ'den olceklendirir.
  parameter int NAC_TIMEOUT_CLK  = 5_000_000,
  // Programlama mesguliyeti icin ust sinir. Table 7-1: beklemeye devam et.
  parameter int PROG_TIMEOUT_CLK = 25_000_000
) (
  input  logic                 clk,              // cmd_clk
  input  logic                 rst_n,

  // ---- L4 istegi -----------------------------------------------------------
  input  logic                 go_i,             // system_controller.xfer_go_o
  input  logic                 card_present_i,
  input  logic                 card_ready_i,     // STATUS.CARD_READY
  input  logic [ultra_sd_pkg::LBA_W-1:0]    lba_i,
  input  logic [ultra_sd_pkg::BLOCKS_W-1:0] blocks_i,
  input  logic                 dir_i,            // 0 = okuma, 1 = yazma
  input  logic [31:0]          card_blk_i,       // REG_CARD_BLK (R-FUNC-4)
  input  logic                 block_addr_i,     // 1 = blok adresleme (CCS)
  input  logic [15:0]          rca_i,            // CMD13 argumani

  // ---- ultra_sd_stat'a olaylar ---------------------------------------------
  output logic                 accept_o,         // istek alindi, 1 cevrim
  output logic                 busy_o,           // transfer suruyor
  output logic                 fin_o,            // bitti (basari ya da hata)
  output logic                 fail_o,           // 1 cevrim
  output ultra_sd_pkg::err_e   fail_code_o,
  output logic                 gap_active_o,     // bloklar arasi bos cevrim
  output logic                 retry_crc_o,      // blok CRC16 yuzunden tekrar

  // ---- L2 komut istegi (arbiter uzerinden) ---------------------------------
  output logic                 req_valid_o,
  output logic [5:0]           req_index_o,
  output logic [31:0]          req_arg_o,
  output ultra_sd_pkg::resp_e  req_resp_o,
  output logic                 req_is_acmd_o,
  input  logic                 req_ready_i,
  input  logic                 rsp_valid_i,
  input  logic                 rsp_err_i,
  input  ultra_sd_pkg::err_e   cmd_err_i,

  // ---- L1 veri motoru ------------------------------------------------------
  output logic                 dat_start_o,      // seviye, busy yukselene kadar
  output logic                 dat_dir_o,        // 1 = yazma
  output logic [31:0]          tx_data_o,
  input  logic                 tx_take_i,
  input  logic                 tx_done_i,
  input  logic                 tx_status_ok_i,
  input  logic                 tx_status_tmo_i,
  input  logic [31:0]          rx_data_i,
  input  logic                 rx_valid_i,
  input  logic                 rx_busy_i,
  input  logic                 rx_done_i,
  input  logic                 rx_crc_ok_i,
  input  logic                 dat_active_i,     // yuk hucresi, Table 5-2
  input  logic                 card_busy_i,      // DAT0 asagida

  // ---- L4 okuma yuku (spekulatif yazma tarafi) -----------------------------
  output logic [DATA_W-1:0]    rd_data_o,
  output logic                 rd_en_o,
  output logic                 rd_commit_o,      // blogun CRC16'si tuttu
  output logic                 rd_rewind_o,      // tutmadi, blogu yok et
  input  logic                 rd_room_ok_i,     // bir blokluk yer var

  // ---- L4 yazma yuku (spekulatif okuma tarafi) -----------------------------
  input  logic [DATA_W-1:0]    wr_data_i,
  input  logic                 wr_last_i,
  output logic                 wr_en_o,
  output logic                 wr_commit_o,      // kart blogu kabul etti
  output logic                 wr_rewind_o,      // olumsuz token, tekrar gonder
  input  logic                 wr_block_ready_i  // tam bir blok hazir
);

  // import

  localparam int TO_W  = $clog2((NAC_TIMEOUT_CLK > PROG_TIMEOUT_CLK)
                                ? NAC_TIMEOUT_CLK + 1 : PROG_TIMEOUT_CLK + 1);
  localparam int RTY_W = $clog2(CRC_RETRIES + 2);

  // SDSC kartta adres bayt cinsindendir. init SDSC'yi ERR_UNSUPPORTED ile
  // reddediyor (R-FUNC-5), yani bu dal pratikte kosmaz; gene de duruyor ki
  // modul kendi basina da dogru olsun.
  localparam int BLOCK_SHIFT = $clog2(BLOCK_BYTES);

  typedef enum logic [3:0] {
    S_IDLE,
    S_PRE_ERASE,  // ACMD23, yalnizca cok bloklu yazma (R-FUNC-11)
    S_RD_ARM,     // FIFO'da bir blokluk yer bekle, L1'i silahla
    S_CMD,        // CMD17 / CMD18 / CMD24 / CMD25
    S_RD_DATA,    // butun bloklarin aktigi adim; her rx_done bir blok
    S_WR_ARM,     // tam blok + bos kart bekle
    S_WR_DATA,    // blogu gonder, CRC durum token'ini bekle
    S_BUSY,       // kart DAT0'i birakana kadar (R1b ve programlama)
    S_STOP,       // CMD12 (R-FUNC-10)
    S_STATUS,     // CMD13, yapiskan bitleri temizle (R-FUNC-16)
    S_DONE,
    S_ERROR
  } step_e;

  typedef enum logic [1:0] { P_ISSUE, P_ACC, P_WAIT } cphase_e;

  // S_BUSY / S_STOP / S_STATUS bittiginde nereye donulecek.
  typedef enum logic [1:0] {
    POST_NEXT,    // siradaki bloga gec (yalnizca yazma)
    POST_RETRY,   // ayni LBA'dan veri komutunu yeniden ac
    POST_DONE,
    POST_ERROR
  } post_e;

  step_e               step_q;
  cphase_e             cphase_q;
  post_e               post_q;

  logic [LBA_W-1:0]    lba_q;          // calisan adres
  logic [BLOCKS_W-1:0] blocks_left_q;
  logic [BLOCKS_W-1:0] blocks_tot_q;   // ACMD23 argumani ve bosluk olcumu
  logic                dir_q;
  logic                multi_q;        // tek CMD18/CMD25 akisi
  logic [TO_W-1:0]     to_q;
  logic [RTY_W-1:0]    retry_q;
  logic                drop_q;         // bu blok artik FIFO'ya yazilmaz
  logic                stopped_q;      // bu akis icin CMD12 gonderildi
  logic                rd_rewind_q;
  logic                wr_rewind_q;

  // ---------------------------------------------------------------------------
  // Sistem saatinden gelen tek-bit kontroller: iki flop (R-CLK-3), sonra kenar.
  // ---------------------------------------------------------------------------
  logic [1:0] go_sync_q, pres_sync_q;
  logic       go_q;

  logic go_rise, go_fall;
  assign go_rise =  go_sync_q[1] & ~go_q;
  assign go_fall = ~go_sync_q[1] &  go_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      go_sync_q   <= 2'b00;
      go_q        <= 1'b0;
      pres_sync_q <= 2'b00;   // kart yok: STATUS.CARD_PRESENT reset degeri
    end else begin
      go_sync_q   <= {go_sync_q[0],   go_i};
      go_q        <= go_sync_q[1];
      pres_sync_q <= {pres_sync_q[0], card_present_i};
    end
  end

  // ---------------------------------------------------------------------------
  // Komut cozucu. Hangi adimda hangi komut gider: tek yerde, kombinasyonel.
  // ---------------------------------------------------------------------------
  logic [5:0]  nx_index;
  logic [31:0] nx_arg;
  resp_e       nx_resp;
  logic        nx_acmd;
  logic [31:0] dat_addr;

  assign dat_addr = block_addr_i ? lba_q : (lba_q << BLOCK_SHIFT);

  always_comb begin
    unique case (step_q)
      S_PRE_ERASE: begin                                  // R-FUNC-11
        nx_index = ACMD23_SET_WR_BLK_ERASE_CNT;
        nx_arg   = {9'h0, blocks_tot_q[22:0]};
        nx_resp  = RESP_R1;
        nx_acmd  = 1'b1;
      end
      S_STOP: begin                                       // R-FUNC-10
        nx_index = CMD12_STOP_TRANSMISSION;
        nx_arg   = 32'h0;
        nx_resp  = RESP_R1B;
        nx_acmd  = 1'b0;
      end
      S_STATUS: begin                                     // R-FUNC-16
        nx_index = CMD13_SEND_STATUS;
        nx_arg   = {rca_i, 16'h0};
        nx_resp  = RESP_R1;
        nx_acmd  = 1'b0;
      end
      default: begin                                      // S_CMD
        nx_index = dir_q ? (multi_q ? CMD25_WRITE_MULTIPLE_BLK
                                    : CMD24_WRITE_BLOCK)
                         : (multi_q ? CMD18_READ_MULTIPLE_BLOCK
                                    : CMD17_READ_SINGLE_BLOCK);
        nx_arg   = dat_addr;
        nx_resp  = RESP_R1;
        nx_acmd  = 1'b0;
      end
    endcase
  end

  logic cmd_step;
  assign cmd_step = (step_q == S_PRE_ERASE) || (step_q == S_CMD) ||
                    (step_q == S_STOP)      || (step_q == S_STATUS);

  assign req_valid_o   = cmd_step && (cphase_q != P_WAIT);
  assign req_index_o   = nx_index;
  assign req_arg_o     = nx_arg;
  assign req_resp_o    = nx_resp;
  assign req_is_acmd_o = nx_acmd;

  // ---------------------------------------------------------------------------
  // Yuk yolu. Okumada L1'den gelen her kelime dogrudan FIFO'ya yazilir --
  // yayinlanmasi CRC'ye bagli oldugu icin burada bir sart gerekmez. Yazmada
  // FIFO show-ahead: L1 kelimeyi aldigi cevrimde pop edilir.
  // ---------------------------------------------------------------------------
  assign rd_data_o = rx_data_i;
  assign rd_en_o   = (step_q == S_RD_DATA) && rx_valid_i && !drop_q;

  assign tx_data_o = wr_data_i;
  assign wr_en_o   = (step_q == S_WR_DATA) && tx_take_i;

  // L1'i silahlama. Okumada seviye akis boyunca yukarida kalir: L1 blogu
  // bitirip IDLE'a dondugunde kendini yeniden silahlar ve bloklar arasina
  // bizim ekledigimiz bir bosluk olmaz (metrik L4).
  assign dat_start_o = (step_q == S_RD_ARM)
                    || ((step_q == S_RD_DATA) && !drop_q && rd_room_ok_i)
                    || (step_q == S_WR_ARM);
  assign dat_dir_o   = dir_q;

  // ---------------------------------------------------------------------------
  // Olaylar. FSM'in uc ayri dali ayni soruyu soruyor, bu yuzden sorular bir
  // kez burada cevaplanir.
  // ---------------------------------------------------------------------------
  logic cmd_ack, cmd_fail, cmd_ok;
  assign cmd_ack  = cmd_step && (cphase_q == P_WAIT) && rsp_valid_i;
  assign cmd_fail = cmd_ack &&  rsp_err_i;
  assign cmd_ok   = cmd_ack && !rsp_err_i;

  logic last_block, need_stop, retry_left;
  assign last_block = (blocks_left_q == BLOCKS_W'(1));
  assign need_stop  = multi_q;                  // CMD17/CMD24 CMD12 istemez
  assign retry_left = (retry_q < RTY_W'(CRC_RETRIES));

  logic rd_block_ok, rd_crc_fail, rd_tmo;
  assign rd_block_ok = (step_q == S_RD_DATA) && rx_done_i &&  rx_crc_ok_i;
  assign rd_crc_fail = (step_q == S_RD_DATA) && rx_done_i && !rx_crc_ok_i;
  assign rd_tmo      = (step_q == S_RD_DATA) && (to_q == '0) && !rx_busy_i;

  logic wr_block_ok, wr_nak, wr_tmo, wr_proto;
  assign wr_block_ok = (step_q == S_WR_DATA) && tx_done_i &&  tx_status_ok_i;
  assign wr_tmo      = (step_q == S_WR_DATA) && tx_done_i &&  tx_status_tmo_i;
  assign wr_nak      = (step_q == S_WR_DATA) && tx_done_i && !tx_status_ok_i &&
                       !tx_status_tmo_i;
  // Host bildirdigi blok sayisindan once akisi kapatti: host tarafi protokol
  // hatasi (Table 5-3).
  assign wr_proto    = wr_en_o && wr_last_i && !last_block;

  logic busy_tmo;
  assign busy_tmo = ((step_q == S_BUSY) || (step_q == S_WR_ARM)) &&
                    (to_q == '0) && card_busy_i;

  logic        abort_evt, start_bad;
  logic [32:0] last_blk;         // lba + blocks, tasmayi gormek icin bir bit
  err_e        start_err;

  assign abort_evt = go_fall && (step_q != S_IDLE) &&
                     (step_q != S_DONE) && (step_q != S_ERROR);

  assign last_blk  = {1'b0, lba_i} + {1'b0, 32'(blocks_i)};
  assign start_err = !pres_sync_q[1]                 ? ERR_NO_CARD
                   : !card_ready_i                   ? ERR_CARD_STATE
                   : (blocks_i == '0)                ? ERR_PROTOCOL
                   : (last_blk > {1'b0, card_blk_i}) ? ERR_RANGE
                                                     : ERR_OK;
  assign start_bad = (step_q == S_IDLE) && go_rise && (start_err != ERR_OK);

  // Transferi bitiren hatalar ve kodlari. Ayni cevrimde ikisi dogru olamaz;
  // sira yalnizca okunabilirlik icin.
  assign fail_o = start_bad || cmd_fail || rd_tmo || wr_tmo || wr_proto ||
                  busy_tmo || (rd_crc_fail && !retry_left) ||
                  (wr_nak && !retry_left) || (abort_evt && !pres_sync_q[1]);

  assign fail_code_o = start_bad               ? start_err
                     : cmd_fail                ? cmd_err_i
                     : abort_evt               ? ERR_NO_CARD
                     : wr_proto                ? ERR_PROTOCOL
                     : (rd_tmo || wr_tmo || busy_tmo) ? ERR_DAT_TIMEOUT
                     : rd_crc_fail             ? ERR_DAT_CRC
                                               : ERR_WR_CRC_TOKEN;

  // Yeniden denenecek blok (R-FUNC-15 / R-FUNC-13).
  assign retry_crc_o = (rd_crc_fail || wr_nak) && retry_left;

  // Veri komutunu yeniden acmayi ya da bitmeyi gerektiren her cikis, akis
  // acikken CMD12'den gecer (hazard D-13: yolda bir blok olabilir).
  logic recover_step;
  assign recover_step = need_stop && !stopped_q;

  // ---- ultra_sd_stat'a sonuc olaylari --------------------------------------
  assign accept_o = (step_q == S_IDLE) && go_rise;
  assign busy_o   = (step_q != S_IDLE) && (step_q != S_DONE) &&
                    (step_q != S_ERROR);
  assign fin_o    = (step_q == S_DONE) || (step_q == S_ERROR);

  // Bosluk: cok bloklu bir transferde iki blok YUKU arasinda gecen bos
  // cevrimler. Kartin programlama mesguliyeti bosluk degildir -- o STAT_BUSY'de
  // sayilir ve yazma verimi formulunde denominatordan cikarilir (Section 12.4).
  logic in_stream;
  assign in_stream    = (step_q == S_RD_DATA) || (step_q == S_WR_ARM) ||
                        (step_q == S_WR_DATA);
  assign gap_active_o = in_stream && !dat_active_i && !card_busy_i && multi_q &&
                        (blocks_left_q != blocks_tot_q);

  // ---------------------------------------------------------------------------
  // Adim FSM'i. Yalnizca akis kontrolu: adres/sayac defteri ve geri sarma
  // darbeleri asagida, ayri bloklarda (R-ARCH-4).
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      step_q    <= S_IDLE;
      post_q    <= POST_NEXT;
      to_q      <= '0;
      drop_q    <= 1'b0;
      stopped_q <= 1'b0;
    end else begin
      if (to_q != '0) to_q <= to_q - TO_W'(1);

      if (abort_evt) begin
        drop_q <= 1'b1;
        post_q <= pres_sync_q[1] ? POST_DONE : POST_ERROR;
        step_q <= recover_step ? S_STOP : S_STATUS;
      end else if (fail_o && (step_q != S_IDLE)) begin
        drop_q <= 1'b1;
        post_q <= POST_ERROR;
        step_q <= (step_q == S_STATUS) ? S_ERROR
                : recover_step         ? S_STOP : S_STATUS;
      end else if (retry_crc_o) begin
        drop_q <= 1'b1;
        post_q <= POST_RETRY;
        step_q <= recover_step ? S_STOP : S_STATUS;
      end else begin
        unique case (step_q)
          S_IDLE: if (go_rise) begin
            drop_q    <= 1'b0;
            stopped_q <= 1'b0;
            step_q    <= start_bad ? S_ERROR
                       : dir_i     ? ((blocks_i > BLOCKS_W'(1)) ? S_PRE_ERASE
                                                                : S_CMD)
                                   : S_RD_ARM;
          end

          // Okuma icin FIFO'da yer bekle. Kart burada BOS: veri komutu henuz
          // gonderilmedi, yani bu bir kart beklemesi degil ve sinirlanmaz
          // (R-FUNC-17 kart beklemelerini sinirlar). L1 simdiden silahlanir,
          // boylece komuttan sonra bir cevrim bile kaybolmaz.
          S_RD_ARM:    if (rd_room_ok_i) step_q <= S_CMD;
          S_PRE_ERASE: if (cmd_ok)       step_q <= S_CMD;

          S_CMD: if (cmd_ok) begin
            drop_q    <= 1'b0;
            stopped_q <= 1'b0;
            to_q      <= dir_q ? TO_W'(PROG_TIMEOUT_CLK)
                               : TO_W'(NAC_TIMEOUT_CLK);
            step_q    <= dir_q ? S_WR_ARM : S_RD_DATA;
          end

          // Butun bloklar bu adimda akar: L1 kendini yeniden silahladigi icin
          // her rx_done_i bir blok demektir.
          S_RD_DATA: if (rd_block_ok) begin
            to_q <= TO_W'(NAC_TIMEOUT_CLK);
            if (last_block) begin
              drop_q <= 1'b1;
              post_q <= POST_DONE;
              step_q <= need_stop ? S_STOP : S_DONE;
            end else if (!rd_room_ok_i) begin
              // Geri basinc: akisi CMD12 ile kapat, yer acilinca yeni CMD18.
              drop_q <= 1'b1;
              post_q <= POST_RETRY;
              step_q <= S_STOP;
            end
          end

          // Yazma. Bir bloga ancak tamami FIFO'da hazirken baslanir (R-IF-8);
          // kart mesgulse once onun bitmesi beklenir (R-FUNC-12).
          S_WR_ARM: if (!card_busy_i && wr_block_ready_i) begin
            to_q   <= TO_W'(NAC_TIMEOUT_CLK);
            step_q <= S_WR_DATA;
          end

          S_WR_DATA: if (wr_block_ok) begin
            to_q   <= TO_W'(PROG_TIMEOUT_CLK);
            post_q <= last_block ? POST_DONE : POST_NEXT;
            step_q <= S_BUSY;
          end

          // Kart DAT0'i birakana kadar. R1b mesguliyeti de programlama
          // mesguliyeti de ayni yerde beklenir (hazard D-5).
          S_BUSY: if (!card_busy_i) begin
            unique case (post_q)
              POST_DONE: step_q <= recover_step ? S_STOP : S_DONE;
              POST_NEXT: step_q <= S_WR_ARM;
              default:   step_q <= S_STATUS;        // RETRY ve ERROR
            endcase
          end

          S_STOP: if (cmd_ok) begin
            stopped_q <= 1'b1;
            to_q      <= TO_W'(PROG_TIMEOUT_CLK);
            step_q    <= S_BUSY;
          end

          S_STATUS: if (cmd_ok) begin
            unique case (post_q)
              POST_RETRY: begin
                drop_q    <= 1'b0;
                stopped_q <= 1'b0;
                step_q    <= dir_q ? S_CMD : S_RD_ARM;
              end
              POST_ERROR: step_q <= S_ERROR;
              default:    step_q <= S_DONE;
            endcase
          end

          // Bitti. go_i dusmeden yeni istek alinmaz: ayni START iki kez
          // baslatilamaz (R-IF-4).
          default: begin                            // S_DONE, S_ERROR
            drop_q <= 1'b0;
            if (!go_sync_q[1]) step_q <= S_IDLE;
          end
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Istek defteri: adres, kalan blok, yon ve tekrar sayaci. START kenarinda
  // yuklenir (R-IF-3: o andaki LBA/BLOCKS/XFER), her islenmis blokta ilerler.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lba_q         <= '0;             // REG_LBA reset degeri ile ayni
      blocks_left_q <= '0;             // acik istek yok
      blocks_tot_q  <= '0;
      dir_q         <= 1'b0;           // REG_XFER.DIR = okuma
      multi_q       <= 1'b0;
      retry_q       <= '0;
    end else if (accept_o) begin
      lba_q         <= lba_i;
      blocks_left_q <= blocks_i;
      blocks_tot_q  <= blocks_i;
      dir_q         <= dir_i;
      multi_q       <= (blocks_i > BLOCKS_W'(1));
      retry_q       <= '0;
    end else if (rd_block_ok || wr_block_ok) begin
      lba_q         <= lba_q + LBA_W'(1);
      blocks_left_q <= blocks_left_q - BLOCKS_W'(1);
      retry_q       <= '0;             // blok gecti, kota tazelenir
    end else if (retry_crc_o) begin
      retry_q       <= retry_q + RTY_W'(1);
    end
  end

  // ---------------------------------------------------------------------------
  // Geri sarma. Yarim kalan ya da reddedilen blok FIFO'da yayinlanmamis
  // kelimeler biraktiysa onlari geri sarmak zorundayiz: aksi halde bir sonraki
  // commit onlari da yayinlar.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_rewind_q <= 1'b0;
      wr_rewind_q <= 1'b0;
    end else begin
      rd_rewind_q <= (fail_o || retry_crc_o || abort_evt) &&
                     (step_q == S_RD_DATA);
      wr_rewind_q <= (fail_o || retry_crc_o || abort_evt) &&
                     (step_q == S_WR_DATA);
    end
  end

  assign rd_commit_o = rd_block_ok;
  assign rd_rewind_o = rd_rewind_q;
  assign wr_commit_o = wr_block_ok;
  assign wr_rewind_o = wr_rewind_q;

  // ---------------------------------------------------------------------------
  // Komut el sikismasinin uc fazi. Adimdan bagimsiz oldugu icin ayri duruyor:
  // dort komut adimi da ayni devreyi kullanir (R-ARCH-4, R-ARCH-5).
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cphase_q <= P_ISSUE;
    end else if (!cmd_step || cmd_ack || abort_evt) begin
      cphase_q <= P_ISSUE;             // adim degisti ya da yanit alindi
    end else begin
      unique case (cphase_q)
        P_ISSUE: cphase_q <= P_ACC;
        P_ACC:   if (req_ready_i) cphase_q <= P_WAIT;
        default: ;                     // P_WAIT: cikisi yukaridaki cmd_ack
      endcase
    end
  end

endmodule

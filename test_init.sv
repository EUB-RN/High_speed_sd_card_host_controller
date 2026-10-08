import ultra_sd_pkg::*;
// -----------------------------------------------------------------------------
// ultra_sd_init
//   Purpose      : L2. Baslatma merdiveni: Section 6.1 ve Appendix B akisi,
//                  tamamen donanimda, yazilim yardimi olmadan. Kart hakkinda
//                  ogrenilen her sey (RCA, kapasite, adresleme tipi, bus
//                  genisligi, hiz kademesi) burada uretilir.
//
//                  Merdiven: CMD0 -> CMD8 -> ACMD41 (yoklama) -> CMD2 ->
//                  CMD3 -> CMD9 -> CMD7 -> ACMD51 -> ACMD6 -> CMD6 (HS).
//
//                  Bu modul CMD hattina BIT seviyesinde dokunmaz: her adim
//                  ultra_sd_cmd'ye bir istek olarak verilir. CMD55 de burada
//                  uretilmez -- ACMD istegi req_is_acmd_o ile isaretlenir ve
//                  oneki ultra_sd_cmd koyar.
//
//                  74-clock rampasi da burada DEGIL: onu system_controller
//                  sayar (SYS_RAMP) ve bitince ramp_done_i'yi seviye olarak
//                  yukari ceker. Rampanin iki yerde sayilmasi, iki ayri
//                  sayacin ayni sarti farkli zamanlarda saglamasi anlamina
//                  gelirdi.
//
//                  FAZ 0 sozlesmesi. Reset altinda FSM INIT_IDLE'dadir,
//                  ultra_sd_cmd'ye acik istek yoktur, karttan ogrenilen her
//                  sey sifirdir: CARD_READY=0, SPEED=SPEED_INIT,
//                  BUS_WIDTH=1-bit, REG_CARD_BLK=0, bolucu en yavas kademe.
//
//   Clock domain : cmd_clk -- ultra_sd_cmd ile AYNI saat. Boylece req_* /
//                  rsp_* el sikismasi ayni alanda kalir ve doc/cdc.md'ye
//                  yeni bir satir gerekmez. El sikisma seviye tabanlidir:
//                  req_valid_o, req_ready_i gorulene kadar basili durur;
//                  rsp_valid_i de seviye olarak okunur, darbe beklenmez.
//   Reset scheme : rst_n, asenkron assert / senkron deassert (R-CLK-1)
//   Implements   : Spec Section 6.1 (init merdiveni), Appendix B (akis semasi),
//                  R-FUNC-1, R-FUNC-3, R-FUNC-5, R-FUNC-16 (sinirli bekleme)
// -----------------------------------------------------------------------------
// Not: paket importu modul govdesinde; parametre listesinden ONCE yapilan
// header importunu iverilog kabul etmiyor.
module ultra_sd_init #(
  // ---- saat kademeleri, clk_controller bolme orani cinsinden ---------------
  // Oranlar SYS_CLK_HZ'e baglidir, bu yuzden parametre: modul icinde hicbir
  // yerde frekans varsayilmaz (R-CLK-2).
  parameter int CLK_DIV_INIT = 250,  // 100 MHz / 250 = 400 kHz
  parameter int CLK_DIV_DS   = 4,    // 100 MHz / 4   = 25 MHz
  parameter int CLK_DIV_HS   = 2,    // 100 MHz / 2   = 50 MHz

  // R-FUNC-16: ACMD41 yoklama penceresi. SD spec ust siniri 1 saniye; birim
  // cmd_clk cevrimidir, cunku init fazinda saat zaten 400 kHz'e sabitlenmis
  // olur (400_000 cevrim = 1 s). Hicbir yerde Hz oranı varsayilmaz.
  parameter int ACMD41_TIMEOUT_CLK = 400_000,
  // ACMD51 / CMD6 veri blogunun gelmesi icin ust sinir.
  parameter int DAT_TIMEOUT_CLK    = 200_000,

  // ACMD41'de istenen OCR penceresi: HCS (bit 30) + 2.7-3.6 V.
  parameter logic [31:0] OCR_REQUEST = 32'h40FF_8000,

  // Merdivenin iki adimi DAT hattindan blok okumayi gerektirir. Ikisi de
  // kapatilabilir: kapaliyken kart 4-bit destekliyor varsayilir ve Default
  // Speed'te kalinir.
  parameter bit SCR_CHECK = 1'b1,    // ACMD51: SD_BUS_WIDTHS okunsun mu
  parameter bit HS_ENABLE = 1'b1     // CMD6: High Speed'e gecilsin mi
) (
  input  logic                      cmd_clk,
  input  logic                      rst_n,

  // ---- tetikleme -----------------------------------------------------------
  input  logic                      card_present_i, // debounce edilmis, seviye
  input  logic                      ramp_done_i,    // system_controller, seviye
  output logic                      init_busy_o,
  output logic                      init_done_o,
  output logic                      init_err_o,
  output ultra_sd_pkg::err_e        err_o,

  // ---- ultra_sd_cmd'ye komut istegi (seviye tabanli) -----------------------
  output logic                      req_valid_o,
  output logic [5:0]                req_index_o,
  output logic [31:0]               req_arg_o,
  output ultra_sd_pkg::resp_e       req_resp_o,
  output logic                      req_is_acmd_o,
  input  logic                      req_ready_i,
  input  logic                      rsp_valid_i,
  // Cercevenin tamami gelir, ama init yalnizca adlandirilmis birkac alani
  // cozer (OCR, RCA, CSD, CMD8 aynasi); kalan bitler bilincli olarak
  // kullanilmaz.
  /* verilator lint_off UNUSED */
  input  logic [ultra_sd_pkg::RESP_LONG_BITS-1:0] rsp_data_i,
  /* verilator lint_on UNUSED */
  input  logic                      rsp_err_i,
  input  ultra_sd_pkg::err_e        cmd_err_i,      // hatanin tam kodu

  // ---- L1'den blok okuma (yalnizca ACMD51 ve CMD6) -------------------------
  output logic                      dat_rd_start_o,
  output logic [10:0]               dat_rd_bytes_o, // 8 (SCR) ya da 64 (switch)
  input  logic [7:0]                dat_rd_byte_i,
  input  logic                      dat_rd_valid_i,
  input  logic                      dat_rd_busy_i,
  input  logic                      dat_rd_crc_ok_i,

  // ---- karttan ogrenilenler ------------------------------------------------
  output logic [15:0]               rca_o,
  output logic [31:0]               card_blk_o,     // REG_CARD_BLK, 512B blok
  output logic                      block_addr_o,   // 1 = blok adresleme (CCS)
  output ultra_sd_pkg::speed_e      speed_o,        // STATUS.SPEED_MODE
  output logic                      bus_4bit_o,     // STATUS.BUS_WIDTH
  output logic [ultra_sd_pkg::CFG_CLK_W-1:0] clk_div_o
);

  // import

  // ---------------------------------------------------------------------------
  // Sabitler: cerceve icindeki alan yerleri ve komut argumanlari
  // ---------------------------------------------------------------------------
  // 48-bit yanitta arguman / durum alani: cerceve bitleri [39:8].
  localparam int ARG_LSB = 8;
  // R2'de icerik [127:8] oturur, yani CSD biti n = cerceve biti n (n >= 8).

  // CMD8 argumani: [11:8] = VHS (0x1 = 2.7-3.6 V), [7:0] = kontrol deseni.
  // Kart ayni argumani R7 icinde aynalar.
  localparam logic [31:0] CMD8_ARG       = 32'h0000_01AA;
  localparam logic [7:0]  CMD8_PATTERN   = 8'hAA;
  localparam logic [3:0]  CMD8_VHS       = 4'h1;
  localparam int          CMD8_VHS_LSB   = 8;
  // ACMD6: bus genisligi alani, 2 = 4-bit.
  localparam logic [31:0] ACMD6_ARG_4BIT = 32'h0000_0002;
  localparam logic [31:0] ACMD6_ARG_1BIT = 32'h0000_0000;
  // CMD6: mode=set, grup 1 = 1 (High Speed), diger gruplar 0xF = degisme.
  localparam logic [31:0] CMD6_ARG_HS    = 32'h80FF_FFF1;

  // SCR'nin 2. baytinda (index 1) SD_BUS_WIDTHS alani durur; bit 2 = 4-bit.
  localparam int SCR_BYTES       = 8;
  localparam int SCR_BW_BYTE     = 1;
  localparam int          SCR_BW_4BIT_BIT = 2;
  // Switch durum blogunun 17. bayti (index 16), alt nibble = grup 1 secimi.
  localparam int SWITCH_BYTES    = 64;
  localparam int SWITCH_FN_BYTE  = 16;
  localparam logic [3:0]  SWITCH_FN_HS    = 4'h1;

  // OCR alanlari.
  localparam int OCR_BUSY_BIT = 31; // 1 = guc kurulum bitti
  localparam int OCR_CCS_BIT  = 30; // 1 = yuksek kapasite, blok adresleme

  // CSD alanlari. R2 cercevesinde CSD biti n dogrudan rsp_data_i[n]'dir.
  localparam int CSD_STRUCT_MSB   = 127;
  localparam int CSD_V2_CSIZE_MSB = 69;  // [69:48], 22 bit
  localparam int CSD_V2_CSIZE_LSB = 48;
  localparam int CSD_V1_CSIZE_MSB = 73;  // [73:62], 12 bit
  localparam int CSD_V1_CSIZE_LSB = 62;
  localparam int CSD_V1_MULT_MSB  = 49;  // [49:47], 3 bit
  localparam int CSD_V1_MULT_LSB  = 47;
  localparam int CSD_RD_BL_MSB    = 83;  // [83:80], 4 bit
  localparam int CSD_RD_BL_LSB    = 80;
  localparam int BLOCK_SHIFT      = 9;   // 512 bayt = 1 << 9

  // TEK bekleme sayaci, iki pencere icin. ACMD41 yoklama penceresi yalnizca
  // INIT_ACMD41 basamaginda, DAT blok penceresi yalnizca P_DAT_RUN fazinda
  // kosar; ikisi ASLA ayni anda acik olmaz (DAT okuyan basamaklar ACMD51 ve
  // CMD6_HS'tir). ultra_sd_line'daki "tek motor, muxlanmis kaynak" mantigi:
  // pahali olan tarafi -- sayac ve karsilastirici -- iki kez ornekleme.
  // Genislik iki pencerenin genisi kadar, yukleme degeri muxlanir.
  localparam int TO_W    = $clog2(ACMD41_TIMEOUT_CLK + 1);
  localparam int DTO_W   = $clog2(DAT_TIMEOUT_CLK + 1);
  localparam int WAIT_W  = (TO_W > DTO_W) ? TO_W : DTO_W;
  localparam int BCNT_W  = $clog2(SWITCH_BYTES + 1);

  // ---------------------------------------------------------------------------
  // Merdiven basamaklari
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    INIT_IDLE,
    INIT_CMD0,        // GO_IDLE_STATE
    INIT_CMD8,        // SEND_IF_COND, SD 2.0 kontrolu
    INIT_ACMD41,      // SD_SEND_OP_COND, HCS'li yoklama
    INIT_CMD2,        // ALL_SEND_CID
    INIT_CMD3,        // SEND_RELATIVE_ADDR, RCA burada ogrenilir
    INIT_CMD9,        // SEND_CSD, kapasite burada cozulur
    INIT_CMD7,        // SELECT_CARD, karti transfer durumuna al
    INIT_ACMD51,      // SEND_SCR, 4-bit destegi (DAT okur)
    INIT_ACMD6,       // SET_BUS_WIDTH
    INIT_CMD6_HS,     // SWITCH_FUNC, durum blogu geri okumali (DAT okur)
    INIT_DONE,
    INIT_ERROR
  } init_state_e;

  // Her basamak ayni dort adimdan gecer, bu yuzden adim kontrolu basamaktan
  // ayri bir kayitta durur: basamak NE gonderilecegini, faz NEREDE oldugunu
  // soyler.
  typedef enum logic [2:0] {
    P_ISSUE,      // istegi kur ve valid'i kaldir
    P_ACC,        // ultra_sd_cmd istegi alana kadar basili tut
    P_WAIT,       // yanit bekle
    P_DAT_START,  // L1'den blok oku istegi
    P_DAT_RUN     // baytlari topla
  } phase_e;

  init_state_e            state_q;
  phase_e                 phase_q;

  logic [5:0]             req_index_q;
  logic [31:0]            req_arg_q;
  resp_e                  req_resp_q;
  logic                   req_is_acmd_q;
  logic                   req_valid_q;

  logic [15:0]            rca_q;
  logic [31:0]            card_blk_q;
  logic                   block_addr_q;
  speed_e                 speed_q;
  logic                   bus_4bit_q;
  logic [CFG_CLK_W-1:0]   clk_div_q;
  logic                   init_done_q;
  logic                   init_err_q;
  err_e                   err_q;

  logic [WAIT_W-1:0]      wait_cnt_q;    // ACMD41 yoklamasi VEYA DAT blogu
  logic [BCNT_W-1:0]      byte_cnt_q;
  logic [7:0]             dat_cap_q;     // ilgilendigimiz tek bayt
  logic                   scr_4bit_q;    // SCR: kart 4-bit destekliyor
  logic                   dat_rd_start_q;
  logic [10:0]            dat_rd_bytes_q;

  // ---------------------------------------------------------------------------
  // Basamak cozucu: her basamagin hangi komutu, hangi argumanla ve hangi
  // yanit formatiyla istedigi tek yerde durur.
  // ---------------------------------------------------------------------------
  logic [5:0]  nx_index;
  logic [31:0] nx_arg;
  resp_e       nx_resp;
  logic        nx_acmd;

  always_comb begin
    nx_index = 6'd0;
    nx_arg   = 32'h0;
    nx_resp  = RESP_NONE;
    nx_acmd  = 1'b0;
    case (state_q)
      INIT_CMD0: begin
        nx_index = CMD0_GO_IDLE_STATE;
        nx_resp  = RESP_NONE;              // CMD0 yanit vermez
      end
      INIT_CMD8: begin
        nx_index = CMD8_SEND_IF_COND;
        nx_arg   = CMD8_ARG;
        nx_resp  = RESP_R7;
      end
      INIT_ACMD41: begin
        nx_index = ACMD41_SD_SEND_OP_COND;
        nx_arg   = OCR_REQUEST;
        nx_resp  = RESP_R3;                // OCR: CRC alani 1111111
        nx_acmd  = 1'b1;                   // oneki CMD55'i cmd koyar
      end
      INIT_CMD2: begin
        nx_index = CMD2_ALL_SEND_CID;
        nx_resp  = RESP_R2;
      end
      INIT_CMD3: begin
        nx_index = CMD3_SEND_RELATIVE_ADDR;
        nx_resp  = RESP_R6;
      end
      INIT_CMD9: begin
        nx_index = CMD9_SEND_CSD;
        nx_arg   = {rca_q, 16'h0000};
        nx_resp  = RESP_R2;
      end
      INIT_CMD7: begin
        nx_index = CMD7_SELECT_CARD;
        nx_arg   = {rca_q, 16'h0000};
        nx_resp  = RESP_R1B;
      end
      INIT_ACMD51: begin
        nx_index = ACMD51_SEND_SCR;
        nx_resp  = RESP_R1;
        nx_acmd  = 1'b1;
      end
      INIT_ACMD6: begin
        nx_index = ACMD6_SET_BUS_WIDTH;
        nx_arg   = scr_4bit_q ? ACMD6_ARG_4BIT : ACMD6_ARG_1BIT;
        nx_resp  = RESP_R1;
        nx_acmd  = 1'b1;
      end
      INIT_CMD6_HS: begin
        nx_index = CMD6_SWITCH_FUNC;
        nx_arg   = CMD6_ARG_HS;
        nx_resp  = RESP_R1;
      end
      default: ;
    endcase
  end

  // DAT okuyan basamakta blok kac bayt. Hangi basamagin okudugunu P_WAIT
  // icindeki basamak secimi belirler.
  logic [10:0]         dat_step_bytes;
  assign dat_step_bytes = (state_q == INIT_ACMD51) ? 11'(SCR_BYTES)
                                                   : 11'(SWITCH_BYTES);

  // ---------------------------------------------------------------------------
  // Yanit alanlari. Hepsi saga dayali cerceveden okunur.
  // ---------------------------------------------------------------------------
  logic [31:0] resp_arg;        // 48-bit cercevenin [39:8] alani
  assign resp_arg = rsp_data_i[ARG_LSB +: 32];

  logic cmd8_ok;
  assign cmd8_ok = (resp_arg[7:0] == CMD8_PATTERN) &&
                   (resp_arg[CMD8_VHS_LSB +: 4] == CMD8_VHS);

  logic ocr_ready;
  logic ocr_ccs;
  assign ocr_ready = resp_arg[OCR_BUSY_BIT];
  assign ocr_ccs   = resp_arg[OCR_CCS_BIT];

  // CSD -> 512 baytlik blok sayisi.
  logic [1:0]  csd_struct;
  logic [21:0] csd_v2_csize;
  logic [11:0] csd_v1_csize;
  logic [2:0]  csd_v1_mult;
  logic [3:0]  csd_rd_bl_len;
  logic [5:0]  csd_v1_shift;
  logic        csd_v1_ok;
  logic [31:0] csd_blocks;

  assign csd_struct    = rsp_data_i[CSD_STRUCT_MSB -: 2];
  assign csd_v2_csize  = rsp_data_i[CSD_V2_CSIZE_MSB : CSD_V2_CSIZE_LSB];
  assign csd_v1_csize  = rsp_data_i[CSD_V1_CSIZE_MSB : CSD_V1_CSIZE_LSB];
  assign csd_v1_mult   = rsp_data_i[CSD_V1_MULT_MSB  : CSD_V1_MULT_LSB];
  assign csd_rd_bl_len = rsp_data_i[CSD_RD_BL_MSB    : CSD_RD_BL_LSB];

  // CSD v1: kapasite = (C_SIZE+1) * 2^(C_SIZE_MULT+2) * 2^READ_BL_LEN bayt.
  // Blok sayisi icin 512'ye bolunur, yani kaydirma 9 azaltilir. READ_BL_LEN
  // 9'un altindaysa blok boyu 512'den kucuktur: desteklenmez.
  assign csd_v1_ok    = (csd_rd_bl_len >= 4'(BLOCK_SHIFT));
  assign csd_v1_shift = 6'(csd_v1_mult) + 6'd2 +
                        6'(csd_rd_bl_len) - 6'(BLOCK_SHIFT);
  // CSD v2: kapasite = (C_SIZE+1) * 512 KB, yani (C_SIZE+1) << 10 blok.
  //
  // Iki surum ayni islemi yapar: (C_SIZE + 1) << kaydirma. Bu yuzden cikisi
  // muxlamak yerine GIRISI muxluyoruz -- tek 32-bit artirici, tek degisken
  // kaydirici. Onceki hali iki ayri toplama uretip 32-bit cikis mux'u ile
  // seciyordu; bu, hicbir zaman ayni anda gerekmeyen iki toplayici demekti.
  logic [21:0] csd_csize_sel;
  logic [5:0]  csd_shift_sel;
  logic        csd_is_v2;

  assign csd_is_v2     = (csd_struct == 2'b01);
  assign csd_csize_sel = csd_is_v2 ? csd_v2_csize : {10'h0, csd_v1_csize};
  assign csd_shift_sel = csd_is_v2 ? 6'd10        : csd_v1_shift;
  assign csd_blocks    = ({10'h0, csd_csize_sel} + 32'd1) << csd_shift_sel;

  // Kartin cekilmesi her basamagi iptal eder: merdiven bastan baslamak
  // zorundadir, cunku takilan kart baska bir kart olabilir.
  logic abort;
  assign abort = !card_present_i;

  // ---------------------------------------------------------------------------
  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) begin
      // ---- FAZ 0 reset degerleri --------------------------------------------
      state_q        <= INIT_IDLE;
      phase_q        <= P_ISSUE;
      req_valid_q    <= 1'b0;       // ultra_sd_cmd'ye istek yok
      req_index_q    <= '0;
      req_arg_q      <= '0;
      req_resp_q     <= RESP_NONE;
      req_is_acmd_q  <= 1'b0;
      rca_q          <= '0;         // kart RCA'yi CMD3'te atar
      card_blk_q     <= '0;         // REG_CARD_BLK = 0: kapasite bilinmiyor
      block_addr_q   <= 1'b0;       // bilinmiyor: bayt adresleme varsay
      speed_q        <= SPEED_INIT; // STATUS.SPEED_MODE = identification
      bus_4bit_q     <= 1'b0;       // STATUS.BUS_WIDTH = 1-bit
      clk_div_q      <= CFG_CLK_W'(CLK_DIV_INIT); // <= 400 kHz
      init_done_q    <= 1'b0;
      init_err_q     <= 1'b0;
      err_q          <= ERR_OK;
      wait_cnt_q     <= '0;
      byte_cnt_q     <= '0;
      dat_cap_q      <= '0;
      scr_4bit_q     <= 1'b0;
      dat_rd_start_q <= 1'b0;
      dat_rd_bytes_q <= '0;
    end else begin
      dat_rd_start_q <= 1'b0;       // tek cevrimlik istek

      if (abort && (state_q != INIT_IDLE)) begin
        // ---- kart cekildi: ogrenilen her sey gecersiz ------------------------
        state_q      <= INIT_IDLE;
        phase_q      <= P_ISSUE;
        req_valid_q  <= 1'b0;
        rca_q        <= '0;
        card_blk_q   <= '0;
        block_addr_q <= 1'b0;
        speed_q      <= SPEED_INIT;
        bus_4bit_q   <= 1'b0;
        clk_div_q    <= CFG_CLK_W'(CLK_DIV_INIT);
        init_done_q  <= 1'b0;
        init_err_q   <= 1'b0;
        err_q        <= ERR_OK;
        scr_4bit_q   <= 1'b0;
      end else begin
        unique case (phase_q)
          // -------------------------------------------------------------------
          // Istegi kur. Basamak cozucusu state_q'ya gore zaten dogru alanlari
          // suruyor, burada yalnizca kayda alinir.
          P_ISSUE: begin
            if ((state_q != INIT_IDLE) && (state_q != INIT_DONE) &&
                (state_q != INIT_ERROR)) begin
              req_index_q   <= nx_index;
              req_arg_q     <= nx_arg;
              req_resp_q    <= nx_resp;
              req_is_acmd_q <= nx_acmd;
              req_valid_q   <= 1'b1;
              phase_q       <= P_ACC;
            end
          end

          // -------------------------------------------------------------------
          // ultra_sd_cmd istegi bu kenarda aldi mi: req_ready_i seviyesi
          // yukaridaysa evet, cunku ayni kenarda o da valid'i gormus olur.
          P_ACC: begin
            if (req_ready_i) begin
              req_valid_q <= 1'b0;
              phase_q     <= P_WAIT;
            end
          end

          // -------------------------------------------------------------------
          // Yanit. ultra_sd_cmd her beklemeyi kendi sinirlar (NCR, tekrar),
          // bu yuzden burada ayri bir komut watchdog'u yok: rsp_valid_i her
          // durumda gelir, ya sonucla ya hatayla.
          P_WAIT: begin
            if (rsp_valid_i) begin
              if (rsp_err_i && (state_q != INIT_ACMD41)) begin
                // Tasima ya da kart durum hatasi: kodu oldugu gibi aktar.
                err_q      <= cmd_err_i;
                init_err_q <= 1'b1;
                state_q    <= INIT_ERROR;
                phase_q    <= P_ISSUE;
              end else begin
                phase_q <= P_ISSUE;   // basamak kendi next'ini asagida secer
                unique case (state_q)
                  // CMD0: yanit yok, sadece gonderildi.
                  INIT_CMD0: state_q <= INIT_CMD8;

                  // CMD8: desen ve voltaj aynasi dogru degilse kart SD 2.0
                  // degil ya da bizim voltajimizi desteklemiyor.
                  INIT_CMD8: begin
                    if (cmd8_ok) begin
                      wait_cnt_q <= WAIT_W'(ACMD41_TIMEOUT_CLK);
                      state_q  <= INIT_ACMD41;
                    end else begin
                      err_q      <= ERR_UNSUPPORTED;
                      init_err_q <= 1'b1;
                      state_q    <= INIT_ERROR;
                    end
                  end

                  // ACMD41: OCR'nin busy biti kalkana kadar yoklanir.
                  // Hata (CRC/timeout) burada da yoklama sayilir, cunku kart
                  // guc kurulumu sirasinda yaniti kacirabilir -- pencere
                  // dolana kadar denenir.
                  INIT_ACMD41: begin
                    if (!rsp_err_i && ocr_ready) begin
                      block_addr_q <= ocr_ccs;  // CCS: blok mu bayt mi adres
                      state_q      <= INIT_CMD2;
                    end else if (wait_cnt_q == '0) begin
                      err_q      <= ERR_INIT;   // 1 s doldu, kart hazir olmadi
                      init_err_q <= 1'b1;
                      state_q    <= INIT_ERROR;
                    end
                    // aksi halde state_q ayni kalir: yeniden yoklanir
                  end

                  // CMD2: CID icerigi su an kullanilmiyor, yalnizca kartin
                  // identification durumuna gecmesi icin gerekli.
                  INIT_CMD2: state_q <= INIT_CMD3;

                  // CMD3: R6'nin [39:24] alani RCA'dir.
                  INIT_CMD3: begin
                    rca_q   <= rsp_data_i[ARG_LSB+16 +: 16];
                    state_q <= INIT_CMD9;
                  end

                  // CMD9: CSD'den blok sayisi. Burasi ayni zamanda saatin
                  // Default Speed'e cikarildigi yer: kart artik identification
                  // hizina mahkum degil.
                  INIT_CMD9: begin
                    if ((csd_struct == 2'b01) || csd_v1_ok) begin
                      card_blk_q <= csd_blocks;
                      clk_div_q  <= CFG_CLK_W'(CLK_DIV_DS);
                      speed_q    <= SPEED_DS;
                      state_q    <= INIT_CMD7;
                    end else begin
                      err_q      <= ERR_UNSUPPORTED; // 512B'den kucuk blok
                      init_err_q <= 1'b1;
                      state_q    <= INIT_ERROR;
                    end
                  end

                  // CMD7: kart artik transfer durumunda. R1b'nin busy'si DAT0
                  // uzerindedir ve L1'in isidir; CMD hatti acisindan komut
                  // bitmistir.
                  INIT_CMD7: begin
                    if (SCR_CHECK) begin
                      state_q <= INIT_ACMD51;
                    end else begin
                      scr_4bit_q <= 1'b1;        // destekliyor varsay
                      state_q    <= INIT_ACMD6;
                    end
                  end

                  // ACMD51 / CMD6: yanittan sonra blok DAT'tan gelir.
                  INIT_ACMD51, INIT_CMD6_HS: begin
                    phase_q <= P_DAT_START;
                  end

                  // ACMD6: bus genisligi karta yazildi.
                  INIT_ACMD6: begin
                    bus_4bit_q <= scr_4bit_q;
                    if (HS_ENABLE) begin
                      state_q <= INIT_CMD6_HS;
                    end else begin
                      init_done_q <= 1'b1;
                      state_q     <= INIT_DONE;
                    end
                  end

                  default: begin
                    err_q      <= ERR_PROTOCOL;
                    init_err_q <= 1'b1;
                    state_q    <= INIT_ERROR;
                  end
                endcase
              end
            end
          end

          // -------------------------------------------------------------------
          P_DAT_START: begin
            dat_rd_start_q <= 1'b1;
            dat_rd_bytes_q <= dat_step_bytes;
            byte_cnt_q     <= '0;
            dat_cap_q      <= '0;
            wait_cnt_q     <= WAIT_W'(DAT_TIMEOUT_CLK);
            phase_q        <= P_DAT_RUN;
          end

          // -------------------------------------------------------------------
          // Baytlar toplanir; yalnizca tek bir bayt ilgimizi cekiyor, o yuzden
          // blok saklanmaz (R-ARCH: init'in FIFO'su yok).
          P_DAT_RUN: begin
            if (dat_rd_valid_i) begin
              if (byte_cnt_q == BCNT_W'((state_q == INIT_ACMD51)
                                        ? SCR_BW_BYTE : SWITCH_FN_BYTE)) begin
                dat_cap_q <= dat_rd_byte_i;
              end
              byte_cnt_q <= byte_cnt_q + BCNT_W'(1);
            end

            if (wait_cnt_q == '0) begin
              err_q      <= ERR_DAT_TIMEOUT;
              init_err_q <= 1'b1;
              state_q    <= INIT_ERROR;
              phase_q    <= P_ISSUE;
            end else begin
              // Geri sayim asagidaki TEK noktada; burada yalnizca sonuc.
              // Blok bitti: L1 busy'yi indirdi ve beklenen bayt sayisi geldi.
              if (!dat_rd_busy_i && (byte_cnt_q >= BCNT_W'(dat_rd_bytes_q))) begin
                phase_q <= P_ISSUE;
                if (!dat_rd_crc_ok_i) begin
                  err_q      <= ERR_DAT_CRC;
                  init_err_q <= 1'b1;
                  state_q    <= INIT_ERROR;
                end else if (state_q == INIT_ACMD51) begin
                  scr_4bit_q <= dat_cap_q[SCR_BW_4BIT_BIT];
                  state_q    <= INIT_ACMD6;
                end else begin
                  // CMD6: grup 1 secimi gerceklesti mi. Olmadiysa hata degil
                  // -- kart Default Speed'te kalir (R-DEG: dusuk kademeye
                  // dusmek calismaya devam etmek demektir).
                  if (dat_cap_q[3:0] == SWITCH_FN_HS) begin
                    clk_div_q <= CFG_CLK_W'(CLK_DIV_HS);
                    speed_q   <= SPEED_HS;
                  end
                  init_done_q <= 1'b1;
                  state_q     <= INIT_DONE;
                end
              end
            end
          end

          default: phase_q <= P_ISSUE;
        endcase

        // ---- bekleme penceresi: TEK geri sayim noktasi ------------------------
        // Iki pencere de buradan sayilir. Yukleme kenarinda sart saglanmaz
        // (yukleyen basamak/faz henuz degismemistir), bu yuzden yuklenen deger
        // ayni kenarda bir eksilmez.
        if (((state_q == INIT_ACMD41) || (phase_q == P_DAT_RUN)) &&
            (wait_cnt_q != '0)) begin
          wait_cnt_q <= wait_cnt_q - WAIT_W'(1);
        end

        // ---- merdivenin baslangici ------------------------------------------
        // Rampa bitmis ve kart takiliysa CMD0 ile basla. ramp_done_i seviye
        // oldugu icin darbe kacirma ihtimali yok.
        if ((state_q == INIT_IDLE) && ramp_done_i && card_present_i) begin
          state_q <= INIT_CMD0;
          phase_q <= P_ISSUE;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  assign init_busy_o    = (state_q != INIT_IDLE) && (state_q != INIT_DONE) &&
                          (state_q != INIT_ERROR);
  assign init_done_o    = init_done_q;
  assign init_err_o     = init_err_q;
  assign err_o          = err_q;

  assign req_valid_o    = req_valid_q;
  assign req_index_o    = req_index_q;
  assign req_arg_o      = req_arg_q;
  assign req_resp_o     = req_resp_q;
  assign req_is_acmd_o  = req_is_acmd_q;

  assign dat_rd_start_o = dat_rd_start_q;
  assign dat_rd_bytes_o = dat_rd_bytes_q;

  assign rca_o          = rca_q;
  assign card_blk_o     = card_blk_q;
  assign block_addr_o   = block_addr_q;
  assign speed_o        = speed_q;
  assign bus_4bit_o     = bus_4bit_q;
  assign clk_div_o      = clk_div_q;

endmodule

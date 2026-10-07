

package ultra_sd_pkg;

  localparam logic [7:0] REG_VERSION     = 8'h00;
  localparam logic [7:0] REG_CTRL_STATUS = 8'h04;

  localparam logic [7:0] REG_LBA         = 8'h08;
  localparam logic [7:0] REG_XFER_CFG    = 8'h0C;
  localparam logic [7:0] REG_HW_CFG      = 8'h10;
  localparam logic [7:0] REG_CARD_BLK    = 8'h14;
  localparam logic [7:0] REG_STAT_DATA   = 8'h18;
  localparam logic [7:0] REG_STAT_GAP    = 8'h1C;
  localparam logic [7:0] REG_STAT_BUSY   = 8'h20;
  localparam logic [7:0] REG_STAT_RETRY  = 8'h24;

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

  localparam logic [5:0] ACMD6_SET_BUS_WIDTH          = 6'd6;
  localparam logic [5:0] ACMD23_SET_WR_BLK_ERASE_CNT  = 6'd23;
  localparam logic [5:0] ACMD41_SD_SEND_OP_COND       = 6'd41;
  localparam logic [5:0] ACMD51_SEND_SCR              = 6'd51;

  typedef enum logic [2:0] {
    RESP_NONE, RESP_R1, RESP_R1B, RESP_R2, RESP_R3, RESP_R6, RESP_R7
  } resp_e;

  localparam int RESP_SHORT_BITS = 48;
  localparam int RESP_LONG_BITS  = 136;

  localparam int CRC7_W  = 7;
  localparam int CRC16_W = 16;

  localparam logic [CRC7_W-1:0]  CRC7_POLY  = 7'h09;
  localparam logic [CRC16_W-1:0] CRC16_POLY = 16'h1021;

  localparam logic [CRC7_W-1:0]  CRC7_INIT  = {CRC7_W{1'b0}};
  localparam logic [CRC16_W-1:0] CRC16_INIT = {CRC16_W{1'b0}};

  localparam int CMD_CRC7_BITS = 40;

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
  localparam int STATUS_SPEED_LSB     = 4;
  localparam int STATUS_BUS_WIDTH_LSB = 6;

  // ---------------------------------------------------------------------------
  // Table 5-2 istatistik sayac genislikleri
  //
  // Sayaclarin her biri olayini URETEN FSM'in icinde ve O FSM'in saatinde
  // durur (R-IF-11: SD saat cevrimi sayilir), yani olcu birimi SD cevrimidir.
  // Siniri belirleyen en HIZLI SD saati, yani High Speed 50 MHz'dir:
  //   STAT_DUR_W = 28 -> 268_435_455 cevrim = 5.37 s  @50 MHz
  //                                         = 671 s   @400 kHz (init)
  // Tasinmasi gereken en uzun tek olcum programlama timeout'u (500 ms), yani
  // 10 kat pay var; 32 bit (85.9 s @50 MHz) olu ust bit demekti.
  // Yeniden deneme sayaclari zaman degil olay sayar: 12 bit = 4095, blok
  // basina CRC_RETRIES 3 oldugu icin binlerce blok once doymaz.
  // Ikisi de SATURASYONLU: tepede durur, boylece deger "en az bu kadar"
  // anlamini korur. Register goruntusu 32 / 16 bit kalir, ust bitler sifir.
  // ---------------------------------------------------------------------------
  localparam int STAT_DUR_W = 28;
  localparam int STAT_RTY_W = 12;

  localparam int CFG_CLK_W            = 8;

  localparam int CFG_PHY_W            = 6;
  localparam int CFG_PHY_PHASE_LSB    = 0;
  localparam int CFG_PHY_PHASE_W      = 4;
  localparam int CFG_PHY_FORCE_1BIT   = 4;
  localparam int CFG_PHY_FORCE_DS     = 5;

  localparam int IRQ_W                = 3;
  localparam int IRQ_DONE_BIT         = 0;
  localparam int IRQ_ERR_BIT          = 1;
  localparam int IRQ_CARD_CHANGE_BIT  = 2;

  localparam int RETRY_CRC_LSB        = 0;
  localparam int RETRY_CMD_LSB        = 16;

  localparam int LBA_W                = 32;
  localparam int BLOCKS_W             = 24;

  localparam int STATUS_LSB           = 0;
  localparam int ERR_LSB              = 8;
  localparam int IRQ_STAT_LSB         = 16;
  localparam int IRQ_EN_LSB           = 24;
  localparam int IRQ_PIN_BIT          = 31;
  localparam int XFER_DIR_BIT         = 31;
  localparam int CFG_CLK_LSB          = 0;
  localparam int CFG_PHY_LSB          = 8;

  localparam int BLOCK_BYTES    = 512;
  localparam int SD_DATA_LANES  = 4;

  typedef enum logic [1:0] {
    SPEED_INIT = 2'd0,
    SPEED_DS   = 2'd1,
    SPEED_HS   = 2'd2
  } speed_e;

  typedef enum logic [2:0] {
    SYS_RESET       = 3'd0,
    SYS_CARD_DETECT = 3'd1,
    SYS_RAMP        = 3'd2,
    SYS_CONFIG      = 3'd3,
    SYS_READ        = 3'd4,
    SYS_WRITE       = 3'd5
  } sys_phase_e;

endpackage

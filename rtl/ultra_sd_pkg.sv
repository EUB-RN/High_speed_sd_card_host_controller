

package ultra_sd_pkg;

  // ---------------------------------------------------------------------------
  // Table 5-1, byte offsets in the 256-byte window. ONE REGISTER PER ROW.
  //
  // Section 5 is normative and exact: "this port list, this register map,
  // these bit positions ... if your names, widths, directions or offsets
  // differ, your design cannot be measured". The benchmark harness is written
  // against these offsets, so they are not a style choice.
  //
  // This used to be a compacted ten-word map: CTRL, STATUS, ERR, IRQ_EN and
  // IRQ_STAT shared one word at 0x04, BLOCKS and XFER shared 0x0C, CFG_CLK and
  // CFG_PHY shared 0x10, and everything above that was four to twenty bytes
  // low. It saved nine address decodes and cost the whole specification: on
  // the client's harness a write to CTRL.START would land on STATUS and a
  // write to BLOCKS would land on LBA.
  //
  // The packing also had a real functional edge of its own, which is how it
  // was found: CFG_CLK and CFG_PHY in one word meant that software setting
  // FORCE_1BIT with a plain 32-bit write zeroed the clock divisor, and divisor
  // zero is not a clock. One register per row makes that unrepresentable.
  // ---------------------------------------------------------------------------
  localparam logic [7:0] REG_VERSION     = 8'h00;
  localparam logic [7:0] REG_CTRL        = 8'h04;
  localparam logic [7:0] REG_STATUS      = 8'h08;
  localparam logic [7:0] REG_ERR         = 8'h0C;
  localparam logic [7:0] REG_LBA         = 8'h10;
  localparam logic [7:0] REG_BLOCKS      = 8'h14;
  localparam logic [7:0] REG_XFER        = 8'h18;
  localparam logic [7:0] REG_CFG_CLK     = 8'h1C;
  localparam logic [7:0] REG_CFG_PHY     = 8'h20;
  localparam logic [7:0] REG_CARD_BLK    = 8'h24;
  localparam logic [7:0] REG_STAT_DATA   = 8'h28;
  localparam logic [7:0] REG_STAT_GAP    = 8'h2C;
  localparam logic [7:0] REG_STAT_BUSY   = 8'h30;
  localparam logic [7:0] REG_STAT_RETRY  = 8'h34;
  localparam logic [7:0] REG_IRQ_EN      = 8'h38;
  localparam logic [7:0] REG_IRQ_STAT    = 8'h3C;

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

  // Every field is now at the bottom of its OWN register (Table 5-1), so these
  // are all zero except XFER.DIR, which Table 5-1 puts at bit 0 of 0x18. They
  // are kept as named constants rather than deleted because the testbenches
  // and the cocotb register model read them, and because a future field added
  // beside one of these should have somewhere to say where it went.
  localparam int STATUS_LSB           = 0;
  localparam int ERR_LSB              = 0;
  localparam int IRQ_STAT_LSB         = 0;
  localparam int IRQ_EN_LSB           = 0;
  localparam int XFER_DIR_BIT         = 0;
  localparam int CFG_CLK_LSB          = 0;
  localparam int CFG_PHY_LSB          = 0;

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

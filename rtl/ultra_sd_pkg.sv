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

  // ---- AXI4-Lite register offsets, Table 5-1 -------------------------------
  localparam logic [7:0] REG_VERSION    = 8'h00; // RO
  localparam logic [7:0] REG_CTRL       = 8'h04; // W1S
  localparam logic [7:0] REG_STATUS     = 8'h08; // RO
  localparam logic [7:0] REG_ERR        = 8'h0C; // RO
  localparam logic [7:0] REG_LBA        = 8'h10; // RW
  localparam logic [7:0] REG_BLOCKS     = 8'h14; // RW
  localparam logic [7:0] REG_XFER       = 8'h18; // RW
  localparam logic [7:0] REG_CFG_CLK    = 8'h1C; // RW
  localparam logic [7:0] REG_CFG_PHY    = 8'h20; // RW
  localparam logic [7:0] REG_CARD_BLK   = 8'h24; // RO
  localparam logic [7:0] REG_STAT_DATA  = 8'h28; // RO
  localparam logic [7:0] REG_STAT_GAP   = 8'h2C; // RO
  localparam logic [7:0] REG_STAT_BUSY  = 8'h30; // RO
  localparam logic [7:0] REG_STAT_RETRY = 8'h34; // RO
  localparam logic [7:0] REG_IRQ_EN     = 8'h38; // RW
  localparam logic [7:0] REG_IRQ_STAT   = 8'h3C; // W1C

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

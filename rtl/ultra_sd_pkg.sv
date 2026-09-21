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

  localparam int unsigned RESP_SHORT_BITS = 48;
  localparam int unsigned RESP_LONG_BITS  = 136; // R2 only, hazard D-4

  // ---- CRC polynomials, Table A-3 -----------------------------------------
  localparam logic [6:0]  CRC7_POLY  = 7'h09;   // x^7 + x^3 + 1
  localparam logic [15:0] CRC16_POLY = 16'h1021; // x^16 + x^12 + x^5 + 1

  // ---- Bus / block geometry ------------------------------------------------
  localparam int unsigned BLOCK_BYTES = 512;

  typedef enum logic [1:0] {
    SPEED_INIT = 2'd0, // <= 400 kHz
    SPEED_DS   = 2'd1, // 25 MHz Default Speed
    SPEED_HS   = 2'd2  // 50 MHz High Speed
  } speed_e;

endpackage

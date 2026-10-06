// -----------------------------------------------------------------------------
// ultra_sd_block
//   Purpose      : L3. LBA -> blok siralamasi, cok-bloklu akis (CMD18/CMD25),
//                  blok FIFO'lari ve backpressure. Satici primitifi YOK, ham
//                  bit kaydirma YOK, AXI sinyali YOK.
//
//                  FAZ 0 sozlesmesi. Reset altinda hicbir istek acik degil:
//                  FSM BLK_IDLE, kalan blok sayaci sifir, hat (L2) istegi
//                  kapali ve STATUS'un BUSY/DONE bitleri dusuktur. Sayaclar
//                  (STAT_DATA, STAT_GAP, STAT_RETRY) sifirdan baslar, boylece
//                  reset sonrasi ilk olcum onceki transferin kalintisini
//                  tasimaz.
//
//   Clock domain : clk (sistem saati); payload FIFO'lari AXI alanina
//                  async_fifo ile gecer (doc/cdc.md, #1 ve #2)
//   Reset scheme : rst_n, asenkron assert / senkron deassert
//   Implements   : Spec Section 6, R-IF-6 .. R-IF-8, Section 11 gecikme metrigi L4
// -----------------------------------------------------------------------------
module ultra_sd_block
  import ultra_sd_pkg::*;
#(
  parameter int DATA_W         = 32,
  parameter int RD_FIFO_BLOCKS = 2,
  parameter int WR_FIFO_BLOCKS = 2,
  parameter int CRC_RETRIES    = 3
) (
  input  logic                 clk,
  input  logic                 rst_n,

  // ---- L4 (register dosyasi) istegi, R-IF-3 --------------------------------
  input  logic                 start_i,        // CTRL.START darbesi
  input  logic                 abort_i,        // CTRL.ABORT darbesi
  input  logic [LBA_W-1:0]     lba_i,
  input  logic [BLOCKS_W-1:0]  blocks_i,
  input  logic                 dir_i,          // 0 = okuma, 1 = yazma
  input  logic                 card_ready_i,
  output logic                 busy_o,         // STATUS.BUSY
  output logic                 done_o,         // STATUS.DONE
  output logic                 err_valid_o,
  output err_e                 err_o,

  // ---- L2'ye komut istegi --------------------------------------------------
  output logic                 req_valid_o,
  output logic [5:0]           req_index_o,
  output logic [31:0]          req_arg_o,
  output resp_e                req_resp_o,
  input  logic                 req_ready_i,
  input  logic                 rsp_valid_i,
  input  logic                 rsp_err_i,

  // ---- L1 veri hatti -------------------------------------------------------
  output logic                 dat_tx_start_o,
  output logic [7:0]           dat_tx_byte_o,
  input  logic                 dat_tx_take_i,
  output logic                 dat_rx_start_o,
  input  logic [7:0]           dat_rx_byte_i,
  input  logic                 dat_rx_valid_i,
  input  logic                 dat_busy_i,
  input  logic                 dat_crc_ok_i,

  // ---- payload FIFO'lari (AXIS tarafina) -----------------------------------
  output logic [DATA_W-1:0]    rd_data_o,
  output logic                 rd_valid_o,
  input  logic                 rd_ready_i,
  output logic                 rd_last_o,
  input  logic [DATA_W-1:0]    wr_data_i,
  input  logic                 wr_valid_i,
  output logic                 wr_ready_o,
  input  logic                 wr_last_i,

  // ---- Table 5-2 sayaclari -------------------------------------------------
  output logic [31:0]          stat_data_o,
  output logic [31:0]          stat_gap_o,
  output logic [15:0]          retry_crc_o
);

  typedef enum logic [2:0] {
    BLK_IDLE,
    BLK_CMD,        // CMD17/18/24/25 gonder
    BLK_XFER,       // blok akisi
    BLK_STOP,       // cok-bloklu transfer sonunda CMD12
    BLK_DONE,
    BLK_ERROR
  } blk_state_e;

  blk_state_e            state_q;
  logic [LBA_W-1:0]      lba_q;         // calisan adres, blok basina artar
  logic [BLOCKS_W-1:0]   blocks_left_q;
  logic [$clog2(BLOCK_BYTES+1)-1:0] byte_cnt_q;
  logic [$clog2(CRC_RETRIES+1)-1:0] retry_q;
  logic                  dir_q;
  logic                  busy_q;
  logic                  done_q;
  logic                  err_valid_q;
  err_e                  err_q;
  logic [31:0]           stat_data_q;
  logic [31:0]           stat_gap_q;
  logic [15:0]           retry_crc_q;
  logic                  req_valid_q;
  logic [5:0]            req_index_q;
  logic [31:0]           req_arg_q;
  resp_e                 req_resp_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      // ---- FAZ 0 reset degerleri --------------------------------------------
      state_q       <= BLK_IDLE;
      lba_q         <= '0;            // REG_LBA reset degeri ile ayni
      blocks_left_q <= '0;            // acik istek yok (REG_BLOCKS reset=1'den
                                      // bagimsiz: o yazilan istek, bu kalan is)
      byte_cnt_q    <= '0;
      retry_q       <= '0;
      dir_q         <= 1'b0;          // REG_XFER.DIR = okuma
      busy_q        <= 1'b0;          // STATUS.BUSY = 0
      done_q        <= 1'b0;          // STATUS.DONE = 0
      err_valid_q   <= 1'b0;
      err_q         <= ERR_OK;
      stat_data_q   <= '0;            // Table 5-2 sayaclari temiz
      stat_gap_q    <= '0;
      retry_crc_q   <= '0;            // STAT_RETRY[15:0]
      req_valid_q   <= 1'b0;          // L2'ye istek yok
      req_index_q   <= '0;
      req_arg_q     <= '0;
      req_resp_q    <= RESP_NONE;
    end else begin
      // TODO: istek yakalama, blok siralamasi, cok-bloklu akis ve CMD12,
      //       CRC yeniden deneme, FIFO backpressure, sayac guncellemesi.
    end
  end

  assign busy_o        = busy_q;
  assign done_o        = done_q;
  assign err_valid_o   = err_valid_q;
  assign err_o         = err_q;
  assign req_valid_o   = req_valid_q;
  assign req_index_o   = req_index_q;
  assign req_arg_o     = req_arg_q;
  assign req_resp_o    = req_resp_q;
  assign stat_data_o   = stat_data_q;
  assign stat_gap_o    = stat_gap_q;
  assign retry_crc_o   = retry_crc_q;

  // TODO: payload FIFO ornekleri (ultra_sd_fifo) ve akis el sikismasi.
  assign rd_data_o      = '0;
  assign rd_valid_o     = 1'b0;
  assign rd_last_o      = 1'b0;
  assign wr_ready_o     = 1'b0;
  assign dat_tx_start_o = 1'b0;
  assign dat_tx_byte_o  = '0;
  assign dat_rx_start_o = 1'b0;

endmodule

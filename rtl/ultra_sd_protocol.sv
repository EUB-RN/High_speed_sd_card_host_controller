// Wiring and ownership only. Initialization and block requests share one
// command transport. The accepted owner is retained through response delivery.
module ultra_sd_protocol
  import ultra_sd_pkg::*;
#(

  parameter int NCR_TIMEOUT_CLK = 64,
  parameter int NCC_GAP_CLK     = 8,
  parameter int CMD_RETRIES     = 3,

  parameter int CLK_DIV_INIT       = 250,
  parameter int CLK_DIV_DS         = 4,
  parameter int CLK_DIV_HS         = 2,
  parameter int ACMD41_TIMEOUT_CLK = 400_000,
  parameter int DAT_TIMEOUT_CLK    = 200_000,
  parameter logic [31:0] OCR_REQUEST = 32'h40FF_8000,
  parameter bit SCR_CHECK          = 1'b1,
  parameter bit HS_ENABLE          = 1'b1
) (
  input  logic                      cmd_clk,
  input  logic                      rst_n,
  input  logic                      soft_clr,

  input  logic                      req_valid_i,
  input  logic [5:0]                req_index_i,
  input  logic [31:0]               req_arg_i,
  input  resp_e                     req_resp_i,
  input  logic                      req_is_acmd_i,
  output logic                      req_ready_o,

  output logic                      rsp_valid_o,
  output logic [RESP_LONG_BITS-1:0] rsp_data_o,
  output logic                      rsp_crc_ok_o,
  output logic                      rsp_err_o,
  output err_e                      err_o,

  output logic                      card_ready_o,

  input  logic                      card_present_i,
  input  logic                      ramp_done_i,

  input  logic                      force_1bit_i,
  input  logic                      force_ds_i,
  output logic                      init_busy_o,
  output logic                      init_done_o,
  output logic                      init_err_o,
  output err_e                      init_err_code_o,

`ifdef ULTRA_SD_DEBUG_PORT

  output logic [63:0]               dbg_o,
`endif

  output logic                      dat_rd_start_o,
  output logic [10:0]               dat_rd_bytes_o,

  /* verilator lint_off UNUSED */
  input  logic [31:0]               dat_rd_data_i,
  /* verilator lint_on UNUSED */
  input  logic                      dat_rd_valid_i,
  input  logic                      dat_rd_busy_i,
  input  logic                      dat_rd_crc_ok_i,

  output logic [15:0]               rca_o,
  output logic [31:0]               card_blk_o,
  output speed_e                    speed_o,
  output logic                      bus_4bit_o,
  output logic [CFG_CLK_W-1:0]      clk_div_o,

  input  logic                      stat_clear_tgl_i,
  output logic [15:0]               stat_retry_cmd_o,

  output logic                      cmd_out_o,
  output logic                      cmd_oe_o,
  input  logic                      cmd_in_i
);

  logic init_req_valid, init_req_ready, init_req_acmd;
  logic [5:0] init_req_index;
  logic [31:0] init_req_arg;
  resp_e init_req_resp;
  logic engine_ready, engine_valid, engine_err, frame_done, cancel;
  logic owner_init_q;
  logic engine_req_valid, engine_clr;
  logic [5:0] engine_index;
  logic [31:0] engine_arg;
  resp_e engine_resp;
  logic engine_acmd;
`ifdef ULTRA_SD_DEBUG_PORT
  logic [5:0] init_dbg;
  logic [6:0] cmd_dbg;
  assign dbg_o = {rsp_data_o[39:8], 8'h0, cmd_in_i, init_dbg[5:4],
                  err_o, engine_err, cmd_dbg[6], owner_init_q,
                  cmd_dbg[5:0], init_dbg[3:0]};
`endif
  assign engine_req_valid = init_busy_o ? init_req_valid : req_valid_i;
  assign engine_index = init_busy_o ? init_req_index : req_index_i;
  assign engine_arg = init_busy_o ? init_req_arg : req_arg_i;
  assign engine_resp = init_busy_o ? init_req_resp : req_resp_i;
  assign engine_acmd = init_busy_o ? init_req_acmd : req_is_acmd_i;
  assign init_req_ready = init_busy_o && engine_ready;
  assign req_ready_o = !init_busy_o && engine_ready;
  assign rsp_valid_o = !owner_init_q && engine_valid;
  assign rsp_err_o = !owner_init_q && engine_err;
  assign engine_clr = soft_clr || cancel;
  always_ff @(posedge cmd_clk or negedge rst_n) begin
    if (!rst_n) owner_init_q <= 1'b0;
    else begin
      if (engine_req_valid && engine_ready) owner_init_q <= init_busy_o;
      if (engine_clr) owner_init_q <= 1'b0;
    end
  end
  ultra_sd_init #(
    .CLK_DIV_INIT(CLK_DIV_INIT), .CLK_DIV_DS(CLK_DIV_DS), .CLK_DIV_HS(CLK_DIV_HS),
    .ACMD41_TIMEOUT_CLK(ACMD41_TIMEOUT_CLK), .DAT_TIMEOUT_CLK(DAT_TIMEOUT_CLK),
    .OCR_REQUEST(OCR_REQUEST), .SCR_CHECK(SCR_CHECK), .HS_ENABLE(HS_ENABLE)
  ) u_init (
    .cmd_clk, .rst_n, .soft_clr, .card_present_i, .ramp_done_i, .force_1bit_i, .force_ds_i,
    .req_valid_o(init_req_valid), .req_index_o(init_req_index), .req_arg_o(init_req_arg),
    .req_resp_o(init_req_resp), .req_is_acmd_o(init_req_acmd), .req_ready_i(init_req_ready),
    .rsp_valid_i(owner_init_q && engine_valid), .rsp_err_i(engine_err),
    .rsp_frame_done_i(owner_init_q && frame_done), .rsp_data_i(rsp_data_o), .cmd_err_i(err_o),
    .init_busy_o, .init_done_o, .init_err_o, .init_err_code_o, .cancel_o(cancel),
    .dat_rd_start_o, .dat_rd_bytes_o, .dat_rd_data_i, .dat_rd_valid_i,
    .dat_rd_busy_i, .dat_rd_crc_ok_i,
    .rca_o, .card_blk_o, .speed_o, .bus_4bit_o, .clk_div_o
`ifdef ULTRA_SD_DEBUG_PORT
    , .dbg_o(init_dbg)
`endif
  );
  ultra_sd_cmd #(
    .NCR_TIMEOUT_CLK(NCR_TIMEOUT_CLK), .NCC_GAP_CLK(NCC_GAP_CLK), .CMD_RETRIES(CMD_RETRIES)
  ) u_engine (
    .cmd_clk, .rst_n, .soft_clr(engine_clr),
    .req_valid_i(engine_req_valid), .req_index_i(engine_index), .req_arg_i(engine_arg),
    .req_resp_i(engine_resp), .req_is_acmd_i(engine_acmd), .rca_i(rca_o),
    .req_ready_o(engine_ready), .rsp_valid_o(engine_valid), .rsp_data_o,
    .rsp_crc_ok_o, .rsp_err_o(engine_err), .err_o, .card_ready_o,
    .rsp_frame_done_o(frame_done), .stat_clear_tgl_i, .stat_retry_cmd_o,
    .cmd_out_o, .cmd_oe_o, .cmd_in_i
`ifdef ULTRA_SD_DEBUG_PORT
    , .dbg_o(cmd_dbg)
`endif
  );
endmodule

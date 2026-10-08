// -----------------------------------------------------------------------------
// bench_axil_master
//   Purpose      : AXI4-Lite master with one outstanding access, driven by a
//                  one-request-at-a-time interface so the sequencer above can be
//                  written as a plain list of register accesses.
//
//                  Deliberately simple-minded: no pipelining, no write/read
//                  overlap. Every access the benchmark makes is either setup
//                  before a transfer or a poll between transfers, so the few
//                  wasted cycles never land inside a measurement window. The
//                  measured transfer itself touches no registers at all -- it
//                  runs on the AXI-Stream side.
//
//                  AW and W are issued together and the two ready signals are
//                  accepted independently (R-IF-1), because the slave is allowed
//                  to take them in either order.
//
//   Clock domain : clk only, same domain as the core's AXI interface.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module bench_axil_master (
  input  logic        clk,
  input  logic        rst_n,

  // ---- request interface ---------------------------------------------------
  input  logic        req_valid_i,   // single-cycle pulse, only when idle
  input  logic        req_we_i,      // 1 = write, 0 = read
  input  logic [7:0]  req_addr_i,
  input  logic [31:0] req_wdata_i,
  output logic        busy_o,        // 1 = access in flight
  output logic        rsp_valid_o,   // single-cycle pulse on completion
  output logic [31:0] rsp_rdata_o,
  output logic [1:0]  rsp_resp_o,    // BRESP or RRESP, non-zero = SLVERR

  // ---- AXI4-Lite master ----------------------------------------------------
  output logic [7:0]  m_awaddr,
  output logic        m_awvalid,
  input  logic        m_awready,
  output logic [31:0] m_wdata,
  output logic [3:0]  m_wstrb,
  output logic        m_wvalid,
  input  logic        m_wready,
  input  logic [1:0]  m_bresp,
  input  logic        m_bvalid,
  output logic        m_bready,
  output logic [7:0]  m_araddr,
  output logic        m_arvalid,
  input  logic        m_arready,
  input  logic [31:0] m_rdata,
  input  logic [1:0]  m_rresp,
  input  logic        m_rvalid,
  output logic        m_rready
);

  typedef enum logic [1:0] {
    A_IDLE,
    A_WRITE,     // AW and/or W still outstanding
    A_WRESP,     // waiting for B
    A_READ       // AR and/or R outstanding
  } state_e;

  state_e      state_q;
  logic        aw_done_q, w_done_q;
  logic [31:0] rdata_q;
  logic [1:0]  resp_q;
  logic        rsp_q;

  assign busy_o      = (state_q != A_IDLE);
  assign rsp_valid_o = rsp_q;
  assign rsp_rdata_o = rdata_q;
  assign rsp_resp_o  = resp_q;

  assign m_wstrb  = 4'hf;
  assign m_bready = 1'b1;
  assign m_rready = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q   <= A_IDLE;
      aw_done_q <= 1'b0;
      w_done_q  <= 1'b0;
      m_awaddr  <= '0;
      m_awvalid <= 1'b0;
      m_wdata   <= '0;
      m_wvalid  <= 1'b0;
      m_araddr  <= '0;
      m_arvalid <= 1'b0;
      rdata_q   <= '0;
      resp_q    <= '0;
      rsp_q     <= 1'b0;
    end else begin
      rsp_q <= 1'b0;

      case (state_q)
        A_IDLE: begin
          if (req_valid_i) begin
            if (req_we_i) begin
              m_awaddr  <= req_addr_i;
              m_awvalid <= 1'b1;
              m_wdata   <= req_wdata_i;
              m_wvalid  <= 1'b1;
              aw_done_q <= 1'b0;
              w_done_q  <= 1'b0;
              state_q   <= A_WRITE;
            end else begin
              m_araddr  <= req_addr_i;
              m_arvalid <= 1'b1;
              state_q   <= A_READ;
            end
          end
        end

        // The two channels are independent: drop each valid as its own ready
        // arrives, and only move on once both have been taken.
        A_WRITE: begin
          if (m_awvalid && m_awready) begin
            m_awvalid <= 1'b0;
            aw_done_q <= 1'b1;
          end
          if (m_wvalid && m_wready) begin
            m_wvalid <= 1'b0;
            w_done_q <= 1'b1;
          end
          if ((aw_done_q || (m_awvalid && m_awready)) &&
              (w_done_q  || (m_wvalid  && m_wready))) begin
            state_q <= A_WRESP;
          end
        end

        A_WRESP: begin
          if (m_bvalid) begin
            resp_q  <= m_bresp;
            rdata_q <= '0;
            rsp_q   <= 1'b1;
            state_q <= A_IDLE;
          end
        end

        A_READ: begin
          if (m_arvalid && m_arready) m_arvalid <= 1'b0;
          if (m_rvalid) begin
            rdata_q <= m_rdata;
            resp_q  <= m_rresp;
            rsp_q   <= 1'b1;
            state_q <= A_IDLE;
          end
        end

        default: state_q <= A_IDLE;
      endcase
    end
  end

endmodule

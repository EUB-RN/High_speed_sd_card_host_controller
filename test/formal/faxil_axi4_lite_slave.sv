// -----------------------------------------------------------------------------
// faxil_axi4_lite_slave
//   Purpose      : Formal wrapper around rtl/axi4/axi4_lite_slave.sv. Holds the
//                  DUT next to ZipCPU's AXI4-Lite property set
//                  (formal/third_party/faxil_slave.v) so that SymbiYosys can
//                  prove the handshake and response rules for *all* inputs,
//                  not just the ones a random testbench happened to drive.
//
//                  Why this and not only the simulation VIP: cocotbext-axi and
//                  common/vip/axi4_lite_monitor.sv can only report the
//                  violations that the stimulus provoked. A proof reports that
//                  no stimulus can provoke one. The property set is also an
//                  independent reading of the same specification our own
//                  monitor encodes, which makes it the third opinion in the
//                  cross-check.
//
//                  The register-file side is left free, which is the point: the
//                  solver may answer the slave's reads with any data and any
//                  response code, including ones the real register file would
//                  never produce, so the proof covers the slave's behaviour
//                  rather than one register file's.
//
//   Third party  : formal/third_party/faxil_slave.v, Gisselquist Technology,
//                  Apache-2.0. Origin and licence are in its own header
//                  (R-IP-3); it is listed in the README references (R-IP-2).
//   Covers       : R-IF-1, R-IF-2
// -----------------------------------------------------------------------------
`default_nettype none

module faxil_axi4_lite_slave #(
  parameter int ADDR_WIDTH = 8,
  parameter int DATA_WIDTH = 32,
  // The whole 256-byte window of Figure 5-1: with an 8-bit address port there
  // is nothing outside it, so the register file's own decode is the only one
  // that answers SLVERR.
  parameter logic [31:0] BASE_ADDR = 32'h0000_0000,
  parameter logic [31:0] HIGH_ADDR = 32'h0000_00FF,
  // Cycles the slave may take to answer a request. 0 disables the liveness
  // bound in the property set; see axi4_lite_slave.sby for why the induction
  // task turns it off.
  parameter int F_MAXDELAY = 12
) (
  input wire clk,
  input wire reset_n,

  input wire [ADDR_WIDTH-1:0]   AWADDR,
  input wire                    AWVALID,
  input wire [DATA_WIDTH-1:0]   WDATA,
  input wire [DATA_WIDTH/8-1:0] WSTRB,
  input wire                    WVALID,
  input wire                    BREADY,
  input wire [ADDR_WIDTH-1:0]   ARADDR,
  input wire                    ARVALID,
  input wire                    RREADY,

  // Free inputs from the register-file side: the solver drives these.
  input wire [DATA_WIDTH-1:0]   rd_data,
  input wire [1:0]              bresp_r,
  input wire [1:0]              rresp_r
);

  wire                    AWREADY, WREADY, BVALID, ARREADY, RVALID;
  wire [1:0]              BRESP, RRESP;
  wire [DATA_WIDTH-1:0]   RDATA;

  wire                    wr_en, rd_en;
  wire [ADDR_WIDTH-1:0]   wr_addr, rd_addr;
  wire [DATA_WIDTH-1:0]   wr_data;
  wire [DATA_WIDTH/8-1:0] wr_strb;

  axi4_lite_slave #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (DATA_WIDTH),
    .BASE_ADDR  (BASE_ADDR),
    .HIGH_ADDR  (HIGH_ADDR)
  ) dut (
    .clk     (clk),
    .reset_n (reset_n),

    .AWADDR (AWADDR), .AWVALID (AWVALID), .AWREADY (AWREADY),
    .WDATA  (WDATA),  .WSTRB   (WSTRB),
    .WVALID (WVALID), .WREADY  (WREADY),
    .BRESP  (BRESP),  .BVALID  (BVALID), .BREADY (BREADY),
    .ARADDR (ARADDR), .ARVALID (ARVALID), .ARREADY (ARREADY),
    .RDATA  (RDATA),  .RRESP   (RRESP),  .RVALID (RVALID), .RREADY (RREADY),

    .wr_en   (wr_en),   .wr_addr (wr_addr), .wr_data (wr_data), .wr_strb (wr_strb),
    .rd_en   (rd_en),   .rd_addr (rd_addr), .rd_data (rd_data),
    .bresp_r (bresp_r), .rresp_r (rresp_r)
  );

  // ---- the property set -----------------------------------------------------
  // F_LGDEPTH 4 is far more outstanding capacity than an AXI4-Lite slave with
  // one buffered response can ever use, so it never limits the proof.
  wire [3:0] f_rd_outstanding, f_wr_outstanding, f_awr_outstanding;

  faxil_slave #(
    .C_AXI_DATA_WIDTH (DATA_WIDTH),
    .C_AXI_ADDR_WIDTH (ADDR_WIDTH),
    .F_LGDEPTH        (4),
    // The slave must answer within a bounded number of cycles. These are the
    // liveness bounds, and they are the properties most likely to catch a
    // handshake that can deadlock rather than merely misbehave.
    .F_AXI_MAXWAIT    (12),
    .F_AXI_MAXDELAY   (F_MAXDELAY),
    .F_AXI_MAXRSTALL  (12),
    // The DUT's reset is asynchronously asserted (R-CLK-1), so its outputs go
    // low the moment reset_n falls rather than on the next edge. Left at 0 the
    // property set reads that as the slave dropping RVALID with RREADY low,
    // and flags a legal reset as a handshake violation.
    .F_OPT_ASYNC_RESET (1'b1)
  ) props (
    .i_clk         (clk),
    .i_axi_reset_n (reset_n),

    .i_axi_awvalid (AWVALID),
    .i_axi_awready (AWREADY),
    .i_axi_awaddr  (AWADDR),
    .i_axi_awprot  (3'b000),

    .i_axi_wvalid  (WVALID),
    .i_axi_wready  (WREADY),
    .i_axi_wdata   (WDATA),
    .i_axi_wstrb   (WSTRB),

    .i_axi_bvalid  (BVALID),
    .i_axi_bready  (BREADY),
    .i_axi_bresp   (BRESP),

    .i_axi_arvalid (ARVALID),
    .i_axi_arready (ARREADY),
    .i_axi_araddr  (ARADDR),
    .i_axi_arprot  (3'b000),

    .i_axi_rvalid  (RVALID),
    .i_axi_rready  (RREADY),
    .i_axi_rdata   (RDATA),
    .i_axi_rresp   (RRESP),

    .f_axi_rd_outstanding  (f_rd_outstanding),
    .f_axi_wr_outstanding  (f_wr_outstanding),
    .f_axi_awr_outstanding (f_awr_outstanding)
  );

`ifdef FORMAL
  reg f_past_valid = 1'b0;
  always @(posedge clk) f_past_valid <= 1'b1;

  // AXI4-Lite has no exclusive access, so EXOKAY is not a response the
  // register file is allowed to invent. Constraining it here keeps the proof
  // about the slave rather than about an illegal register file.
  always @(*) begin
    assume (bresp_r != 2'b01);
    assume (rresp_r != 2'b01);
  end

  // The register-file contract, made explicit.
  //
  // axi4_lite_slave drives BRESP straight through from bresp_r while BVALID is
  // held, so AXI4-Lite's "BRESP is stable across a stalled B handshake" rule
  // holds only if bresp_r itself is stable for that long. The slave's own
  // header states the assumption -- the register file answers one cycle after
  // the write and holds until the next one -- but nothing enforced it, and the
  // proof found it immediately: left free, the solver changes bresp_r under a
  // held BVALID and the protocol breaks.
  //
  // Assuming it here is what makes this a proof about the slave rather than
  // about an arbitrary register file. It is also the obligation ultra_sd_reg.sv
  // has to keep: a register file that re-drives bresp_r while a response is
  // outstanding makes the slave non-compliant, and that is now written down
  // somewhere a tool reads.
  //
  // RDATA and RRESP need no such assumption: the slave registers them at the
  // AR handshake, so the read channel is stable by construction.
  always @(posedge clk)
    if (f_past_valid && reset_n && $past(BVALID && !BREADY))
      assume ($stable(bresp_r));

  // ---- the induction invariant ----------------------------------------------
  //
  // THE SLAVE BUFFERS EXACTLY ONE RESPONSE PER CHANNEL, AND THAT HAS TO BE
  // SAID OUT LOUD OR INDUCTION CANNOT KNOW IT.
  //
  // Base-case BMC passes on its own: starting from reset, the slave never gets
  // anywhere near the property set's F_LGDEPTH capacity. Induction does not
  // start from reset. It starts from an arbitrary assignment of every state
  // bit, so it is free to begin with fourteen reads in flight and RVALID low,
  // and from there faxil_slave's own
  //     if (f_axi_rd_outstanding == 4'b1110) assert(!i_axi_arready)
  //   (faxil_slave.v:596-598)
  // fails immediately -- the slave holds ARREADY high because, as far as its
  // own state goes, nothing is outstanding at all. That is the counterexample
  // the prove task was reporting, and it is a statement about an unreachable
  // state rather than about the slave.
  //
  // What closes it is not a bound on the counters -- that passes the base case
  // and fails the step for exactly the same reason -- but an EQUALITY tying
  // each counter to the one bit of slave state that actually tracks it:
  //
  //   read   ARREADY = !RVALID || RREADY, and RVALID is set on the AR
  //          handshake and cleared on the R handshake, both on the same edge
  //          the counter moves. So outstanding reads == RVALID, always. A
  //          back-to-back accept (AR handshake while R handshake completes)
  //          leaves both at 1, which the equality already covers.
  //
  //   write  AWREADY and WREADY each require the other channel's VALID, so the
  //          two write handshakes are the same cycle by construction and the
  //          two counters move together. BVALID is set on that cycle and
  //          cleared on the B handshake, so both equal BVALID.
  //
  // These are assertions, not assumptions: BMC proves them from reset, and
  // induction then gets to use them to rule out the states it was inventing.
  // If the slave is ever changed to buffer more than one response they fail
  // here first, which is the right place to find out.
  always @(posedge clk)
    if (f_past_valid && reset_n) begin
      assert (f_rd_outstanding  == {3'b000, RVALID});
      assert (f_wr_outstanding  == {3'b000, BVALID});
      assert (f_awr_outstanding == {3'b000, BVALID});
    end

`endif

endmodule

`default_nettype wire

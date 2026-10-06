// -----------------------------------------------------------------------------
// axi4_lite_monitor
//   Purpose      : Passive AXI4-Lite protocol monitor. Watches all five
//                  channels and reports the first cycle in which the traffic
//                  stops being legal AMBA, independently of what the slave
//                  does with the data. It drives nothing.
//
//                  Each property is one clause of IHI0022, named in
//                  common/vip/vip_props.svh and cited where it is checked. A
//                  violation sets a sticky bit in `fired`, so
//                  test/vip/tb_vip_selftest.sv can prove that each property
//                  actually detects its own violation -- a checker that never
//                  fires is indistinguishable from no checker at all.
//
//                  Sampling convention: everything is evaluated at posedge
//                  clk against a registered copy of the previous cycle, which
//                  is how the handshake rules are worded ("until READY is
//                  asserted"). n_checks counts armed evaluations, not cycles,
//                  so a monitor that saw no traffic reports zero rather than
//                  a large number of vacuous passes.
//
//   Covers       : R-IF-1 (all five channels), R-IF-2 (SLVERR on unmapped)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "vip/vip_props.svh"

module axi4_lite_monitor #(
  parameter int    ADDR_W = 32,
  parameter int    DATA_W = 32,
  // Prefix on every message, so several monitors in one simulation stay
  // distinguishable.
  // Icarus 11 rejects a `string`-typed parameter; an untyped one holds the
  // literal and prints with %s just the same.
  parameter        NAME   = "axil",
  // Report the first violation of each property only. The first one is the
  // diagnostic; the thousand that follow it are noise.
  parameter bit    QUIET_REPEAT = 1'b1,
  // The self-test commits violations on purpose and does not want them
  // printed; everyone else does.
  parameter bit    VERBOSE      = 1'b1
) (
  input logic                  clk,
  input logic                  rst_n,

  // Pulse high for one cycle to forget everything. A port rather than only a
  // task, because a cocotb test drives signals and cannot call an SV task.
  input logic                  clear_i,

  input logic [ADDR_W-1:0]     awaddr,
  input logic                  awvalid,
  input logic                  awready,

  input logic [DATA_W-1:0]     wdata,
  input logic [DATA_W/8-1:0]   wstrb,
  input logic                  wvalid,
  input logic                  wready,

  input logic [1:0]            bresp,
  input logic                  bvalid,
  input logic                  bready,

  input logic [ADDR_W-1:0]     araddr,
  input logic                  arvalid,
  input logic                  arready,

  input logic [DATA_W-1:0]     rdata,
  input logic [1:0]            rresp,
  input logic                  rvalid,
  input logic                  rready
);

  localparam int BYTES     = DATA_W / 8;
  localparam int ALIGN_LSB = (BYTES <= 1) ? 0 : $clog2(BYTES);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;
  localparam logic [1:0] RESP_DECERR = 2'b11;

  // ---- scoreboard -----------------------------------------------------------
  int                   n_checks = 0;
  int                   n_viol   = 0;
  logic [`AXIL_NPROP-1:0] fired  = '0;

  // Transaction accounting, also the basis of the unsolicited-response and
  // drain properties.
  int aw_acc = 0, w_acc = 0, b_acc = 0, ar_acc = 0, r_acc = 0;

  task automatic violation(input int prop, input string what);
    n_viol++;
    if (VERBOSE && !(QUIET_REPEAT && fired[prop]))
      $display("  VIOLATION [%s] p%0d %s  at %0t", NAME, prop, what, $time);
    fired[prop] = 1'b1;
  endtask

  // An armed property: one that had something to say this cycle.
  task automatic armed(input int prop, input logic ok, input string what);
    n_checks++;
    if (!ok) violation(prop, what);
  endtask

  // ---- the previous cycle ---------------------------------------------------
  logic                p_rst_n  = 1'b0;
  logic                p_awvalid = 1'b0, p_awready = 1'b0;
  logic [ADDR_W-1:0]   p_awaddr  = '0;
  logic                p_wvalid  = 1'b0, p_wready  = 1'b0;
  logic [DATA_W-1:0]   p_wdata   = '0;
  logic [DATA_W/8-1:0] p_wstrb   = '0;
  logic                p_bvalid  = 1'b0, p_bready  = 1'b0;
  logic [1:0]          p_bresp   = '0;
  logic                p_arvalid = 1'b0, p_arready = 1'b0;
  logic [ADDR_W-1:0]   p_araddr  = '0;
  logic                p_rvalid  = 1'b0, p_rready  = 1'b0;
  logic [DATA_W-1:0]   p_rdata   = '0;
  logic [1:0]          p_rresp   = '0;

  // True when both this cycle and the previous one were out of reset, which is
  // the window in which a "must not change since last cycle" rule has meaning.
  logic steady;
  assign steady = rst_n && p_rst_n;

  always @(posedge clk) begin

   if (clear_i) begin
    n_checks = 0;
    n_viol   = 0;
    fired    = '0;
    aw_acc = 0; w_acc = 0; b_acc = 0; ar_acc = 0; r_acc = 0;
   end else begin

    // ---- A3.1.2  VALID low in reset ---------------------------------------
    if (!rst_n) begin
      armed(`AXIL_P_RESET_VALID_LOW,
            !(awvalid || wvalid || bvalid || arvalid || rvalid),
            "a VALID was high while rst_n was low");
    end

    if (steady) begin

      // ---- A3.2.1  VALID held until READY ----------------------------------
      if (p_awvalid && !p_awready)
        armed(`AXIL_P_AW_VALID_HELD, awvalid, "AWVALID dropped before AWREADY");
      if (p_wvalid && !p_wready)
        armed(`AXIL_P_W_VALID_HELD,  wvalid,  "WVALID dropped before WREADY");
      if (p_bvalid && !p_bready)
        armed(`AXIL_P_B_VALID_HELD,  bvalid,  "BVALID dropped before BREADY");
      if (p_arvalid && !p_arready)
        armed(`AXIL_P_AR_VALID_HELD, arvalid, "ARVALID dropped before ARREADY");
      if (p_rvalid && !p_rready)
        armed(`AXIL_P_R_VALID_HELD,  rvalid,  "RVALID dropped before RREADY");

      // ---- A3.2.2  payload stable across a stalled handshake ---------------
      if (p_awvalid && !p_awready && awvalid)
        armed(`AXIL_P_AW_STABLE, awaddr === p_awaddr,
              "AWADDR changed while AWVALID was stalled");
      if (p_wvalid && !p_wready && wvalid)
        armed(`AXIL_P_W_STABLE, (wdata === p_wdata) && (wstrb === p_wstrb),
              "WDATA/WSTRB changed while WVALID was stalled");
      if (p_bvalid && !p_bready && bvalid)
        armed(`AXIL_P_B_STABLE, bresp === p_bresp,
              "BRESP changed while BVALID was stalled");
      if (p_arvalid && !p_arready && arvalid)
        armed(`AXIL_P_AR_STABLE, araddr === p_araddr,
              "ARADDR changed while ARVALID was stalled");
      if (p_rvalid && !p_rready && rvalid)
        armed(`AXIL_P_R_STABLE, (rdata === p_rdata) && (rresp === p_rresp),
              "RDATA/RRESP changed while RVALID was stalled");
    end

    if (rst_n) begin
      // ---- A3.2.2  no undriven payload under a live VALID ------------------
      if (awvalid)
        armed(`AXIL_P_NO_X, !`VIP_HAS_X(awaddr), "AWADDR has x/z while AWVALID");
      // A3.2.2 only requires the byte lanes WSTRB selects to be driven: a
      // narrow write leaves the others undefined, and flagging those would
      // make every legal sub-word write a violation.
      //
      if (wvalid) begin
        armed(`AXIL_P_NO_X, !`VIP_HAS_X(wstrb),
              $sformatf("WSTRB has x/z while WVALID (wstrb=%b)", wstrb));
        if (!`VIP_HAS_X(wstrb))
          for (int i = 0; i < DATA_W/8; i++)
            if (wstrb[i])
              armed(`AXIL_P_NO_X, !`VIP_HAS_X(wdata[8*i +: 8]),
                    $sformatf("WDATA byte %0d has x/z under a live WSTRB (wdata=%h wstrb=%b)",
                              i, wdata, wstrb));
      end
      if (bvalid)
        armed(`AXIL_P_NO_X, !`VIP_HAS_X(bresp), "BRESP has x/z while BVALID");
      if (arvalid)
        armed(`AXIL_P_NO_X, !`VIP_HAS_X(araddr), "ARADDR has x/z while ARVALID");
      if (rvalid)
        armed(`AXIL_P_NO_X, !`VIP_HAS_X(rdata) && !`VIP_HAS_X(rresp),
              $sformatf("RDATA/RRESP has x/z while RVALID (rdata=%h rresp=%b)",
                        rdata, rresp));

      // ---- B1.1.1  only OKAY, SLVERR or DECERR on an AXI4-Lite response ----
      if (bvalid && !`VIP_HAS_X(bresp))
        armed(`AXIL_P_RESP_LEGAL,
              (bresp == RESP_OKAY) || (bresp == RESP_SLVERR) || (bresp == RESP_DECERR),
              "BRESP is EXOKAY, which AXI4-Lite does not define");
      if (rvalid && !`VIP_HAS_X(rresp))
        armed(`AXIL_P_RESP_LEGAL,
              (rresp == RESP_OKAY) || (rresp == RESP_SLVERR) || (rresp == RESP_DECERR),
              "RRESP is EXOKAY, which AXI4-Lite does not define");

      // ---- B1.1  aligned to the data bus width -----------------------------
      if (ALIGN_LSB > 0) begin
        if (awvalid && !`VIP_HAS_X(awaddr))
          armed(`AXIL_P_ADDR_ALIGNED, awaddr[ALIGN_LSB-1:0] == '0,
                "AWADDR is not aligned to the data bus width");
        if (arvalid && !`VIP_HAS_X(araddr))
          armed(`AXIL_P_ADDR_ALIGNED, araddr[ALIGN_LSB-1:0] == '0,
                "ARADDR is not aligned to the data bus width");
      end

      // ---- A3.3.1  no response without its request -------------------------
      // Evaluated before this cycle's handshakes are counted, so a B in the
      // same cycle as the AW that earns it is legal, and a B ahead of it is
      // not.
      if (bvalid && bready)
        armed(`AXIL_P_B_UNSOLICITED,
              (b_acc < (aw_acc + (awvalid && awready ? 1 : 0))) &&
              (b_acc < (w_acc  + (wvalid  && wready  ? 1 : 0))),
              "a write response arrived without a matching request");
      if (rvalid && rready)
        armed(`AXIL_P_R_UNSOLICITED,
              r_acc < (ar_acc + (arvalid && arready ? 1 : 0)),
              "a read response arrived without a matching request");

      // ---- transaction accounting ------------------------------------------
      if (awvalid && awready) aw_acc++;
      if (wvalid  && wready ) w_acc++;
      if (bvalid  && bready ) b_acc++;
      if (arvalid && arready) ar_acc++;
      if (rvalid  && rready ) r_acc++;
    end

   end

    // ---- register this cycle ------------------------------------------------
    p_rst_n   <= rst_n;
    p_awvalid <= awvalid; p_awready <= awready; p_awaddr <= awaddr;
    p_wvalid  <= wvalid;  p_wready  <= wready;  p_wdata  <= wdata; p_wstrb <= wstrb;
    p_bvalid  <= bvalid;  p_bready  <= bready;  p_bresp  <= bresp;
    p_arvalid <= arvalid; p_arready <= arready; p_araddr <= araddr;
    p_rvalid  <= rvalid;  p_rready  <= rready;  p_rdata  <= rdata; p_rresp <= rresp;
  end

  // ---- end of test ----------------------------------------------------------
  // A3.3.1: every accepted request is answered. Called by the testbench once
  // its stimulus has drained, because only the testbench knows when that is.
  task automatic check_drained;
    n_checks++;
    if ((b_acc != aw_acc) || (b_acc != w_acc) || (r_acc != ar_acc)) begin
      violation(`AXIL_P_DRAINED, "requests left unanswered at end of test");
      $display("    [%s] AW=%0d W=%0d B=%0d  AR=%0d R=%0d",
               NAME, aw_acc, w_acc, b_acc, ar_acc, r_acc);
    end
  endtask

  task automatic report;
    $display("  [%s] %0d writes, %0d reads, %0d armed checks, %0d violations",
             NAME, b_acc, r_acc, n_checks, n_viol);
  endtask

  // Forget everything. The self-test reuses one monitor across many
  // deliberately illegal scenarios and needs a clean slate between them.
  task automatic clear;
    n_checks = 0;
    n_viol   = 0;
    fired    = '0;
    aw_acc = 0; w_acc = 0; b_acc = 0; ar_acc = 0; r_acc = 0;
  endtask

endmodule

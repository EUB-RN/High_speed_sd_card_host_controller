// -----------------------------------------------------------------------------
// tb_vip_selftest
//   Purpose      : Verification of the verification. Every property in
//                  common/vip/axi4_lite_monitor.sv and
//                  common/vip/axis_monitor.sv is committed on purpose, one at
//                  a time, and this testbench asserts that the monitor set
//                  exactly the matching bit of `fired` -- not a different one,
//                  and not several.
//
//                  Without this, a monitor that never fires is
//                  indistinguishable from no monitor at all: it would make
//                  every regression greener and catch nothing. The SV monitors
//                  are the Python-free checkers the functional and stress
//                  categories embed, so this is where the right to trust them
//                  comes from. The second half of that right is
//                  test/vip/cocotb/, where they run beside cocotbext-axi on
//                  identical traffic and have to agree.
//
//                  There is no DUT. The monitors are driven directly, because
//                  the stimulus here is illegal on purpose and no correct
//                  slave would produce it.
//
//                  The last scenario is the one that matters most in the
//                  other direction: entirely legal traffic, which must fire
//                  nothing. A checker that fires on good traffic is worse
//                  than one that misses bad traffic -- it gets switched off.
//
//   Covers       : the monitors themselves, hence R-DEL-7 one level up
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "vip/vip_props.svh"

module tb_vip_selftest;

  localparam int ADDR_W = 32;
  localparam int DATA_W = 32;
  localparam time TCK = 10ns;

  logic clk = 1'b0;
  always #(TCK / 2) clk = ~clk;

  // ---- scoreboard -----------------------------------------------------------
  int   n_checks = 0;
  int   n_fails  = 0;

  task automatic fail(input string what);
    n_fails++;
    $display("  FAIL  %s", what);
  endtask

  // ---------------------------------------------------------------------------
  // AXI4-Lite side
  // ---------------------------------------------------------------------------
  logic              rst_n, clear;
  logic [ADDR_W-1:0] awaddr;
  logic              awvalid, awready;
  logic [DATA_W-1:0] wdata;
  logic [3:0]        wstrb;
  logic              wvalid, wready;
  logic [1:0]        bresp;
  logic              bvalid, bready;
  logic [ADDR_W-1:0] araddr;
  logic              arvalid, arready;
  logic [DATA_W-1:0] rdata;
  logic [1:0]        rresp;
  logic              rvalid, rready;

  axi4_lite_monitor #(
    .ADDR_W  (ADDR_W),
    .DATA_W  (DATA_W),
    .NAME    ("selftest.axil"),
    .VERBOSE (1'b0)             // the violations below are the point, not news
  ) mon (
    .clk (clk), .rst_n (rst_n), .clear_i (clear),
    .awaddr (awaddr), .awvalid (awvalid), .awready (awready),
    .wdata (wdata), .wstrb (wstrb), .wvalid (wvalid), .wready (wready),
    .bresp (bresp), .bvalid (bvalid), .bready (bready),
    .araddr (araddr), .arvalid (arvalid), .arready (arready),
    .rdata (rdata), .rresp (rresp), .rvalid (rvalid), .rready (rready)
  );

  // ---------------------------------------------------------------------------
  // AXI4-Stream side
  // ---------------------------------------------------------------------------
  logic [DATA_W-1:0] tdata;
  logic              tvalid, tready, tlast;
  logic [31:0]       pkt_beats;

  axis_monitor #(
    .DATA_W  (DATA_W),
    .NAME    ("selftest.axis"),
    .VERBOSE (1'b0)
  ) amon (
    .clk (clk), .rst_n (rst_n), .clear_i (clear),
    .pkt_beats_i (pkt_beats),
    .tdata (tdata), .tvalid (tvalid), .tready (tready), .tlast (tlast)
  );

  // ---- stimulus helpers -----------------------------------------------------
  task automatic step(input int n = 1);
    for (int i = 0; i < n; i++) @(posedge clk);
  endtask

  task automatic axil_idle;
    awaddr  = '0; awvalid = 1'b0; awready = 1'b0;
    wdata   = '0; wstrb   = 4'hF; wvalid  = 1'b0; wready = 1'b0;
    bresp   = 2'b00; bvalid = 1'b0; bready = 1'b0;
    araddr  = '0; arvalid = 1'b0; arready = 1'b0;
    rdata   = '0; rresp   = 2'b00; rvalid = 1'b0; rready = 1'b0;
  endtask

  task automatic axis_idle;
    tdata  = '0; tvalid = 1'b0; tready = 1'b0; tlast = 1'b0;
  endtask

  // Start a scenario from a known-good, counter-free state.
  task automatic begin_scenario;
    axil_idle;
    axis_idle;
    rst_n     = 1'b1;
    pkt_beats = 32'd0;
    step(2);
    clear = 1'b1;
    step(1);
    clear = 1'b0;
    step(1);
  endtask

  // One legal single-beat write, so that a scenario which needs a write
  // response to exist can have one without tripping the unsolicited property.
  task automatic legal_write(input logic [ADDR_W-1:0] addr);
    awaddr  = addr; awvalid = 1'b1; awready = 1'b1;
    wdata   = 32'hDEAD_BEEF; wstrb = 4'hF; wvalid = 1'b1; wready = 1'b1;
    step(1);
    awvalid = 1'b0; awready = 1'b0; wvalid = 1'b0; wready = 1'b0;
    bresp   = 2'b00; bvalid  = 1'b1; bready = 1'b1;
    step(1);
    bvalid  = 1'b0; bready = 1'b0;
    step(1);
  endtask

  // The request half of a write, without its response: a scenario that wants
  // to hold a B beat needs the credit that earns it, and must not spend that
  // credit on a response of its own.
  task automatic earn_write_credit(input logic [ADDR_W-1:0] addr);
    awaddr  = addr; awvalid = 1'b1; awready = 1'b1;
    wdata   = 32'hDEAD_BEEF; wstrb = 4'hF; wvalid = 1'b1; wready = 1'b1;
    step(1);
    awvalid = 1'b0; awready = 1'b0; wvalid = 1'b0; wready = 1'b0;
    step(1);
  endtask

  task automatic earn_read_credit(input logic [ADDR_W-1:0] addr);
    araddr  = addr; arvalid = 1'b1; arready = 1'b1;
    step(1);
    arvalid = 1'b0; arready = 1'b0;
    step(1);
  endtask

  // One legal single-beat read.
  task automatic legal_read(input logic [ADDR_W-1:0] addr);
    araddr  = addr; arvalid = 1'b1; arready = 1'b1;
    step(1);
    arvalid = 1'b0; arready = 1'b0;
    rdata   = 32'h1234_5678; rresp = 2'b00; rvalid = 1'b1; rready = 1'b1;
    step(1);
    rvalid  = 1'b0; rready = 1'b0;
    step(1);
  endtask

  // ---- the verdict for one scenario -----------------------------------------
  // `want` is the exact set of properties the scenario was built to violate.
  // Anything else firing is a false positive and anything missing is a hole,
  // and both are failures here.
  task automatic expect_axil(input logic [`AXIL_NPROP-1:0] want, input string name);
    logic [`AXIL_NPROP-1:0] got;
    step(2);
    got = mon.fired;
    n_checks++;
    if (got !== want)
      fail($sformatf("%s: axil fired 0b%b, expected 0b%b", name, got, want));
  endtask

  task automatic expect_axis(input logic [`AXIS_NPROP-1:0] want, input string name);
    logic [`AXIS_NPROP-1:0] got;
    step(2);
    got = amon.fired;
    n_checks++;
    if (got !== want)
      fail($sformatf("%s: axis fired 0b%b, expected 0b%b", name, got, want));
  endtask

  function automatic logic [`AXIL_NPROP-1:0] axil_bit(input int p);
    axil_bit = '0;
    axil_bit[p] = 1'b1;
  endfunction

  function automatic logic [`AXIS_NPROP-1:0] axis_bit(input int p);
    axis_bit = '0;
    axis_bit[p] = 1'b1;
  endfunction

  // ---------------------------------------------------------------------------
  // The scenarios
  // ---------------------------------------------------------------------------
  initial begin
    clear = 1'b0;
    rst_n = 1'b0;
    axil_idle;
    axis_idle;
    pkt_beats = 32'd0;
    step(4);

    $display("tb_vip_selftest: each scenario below breaks one rule on purpose");

    // ---- A3.2.1  VALID dropped before READY, one channel at a time ---------
    begin_scenario;
    awvalid = 1'b1; awready = 1'b0; awaddr = 32'h10;
    step(1);
    awvalid = 1'b0;
    expect_axil(axil_bit(`AXIL_P_AW_VALID_HELD), "AWVALID dropped");

    begin_scenario;
    wvalid = 1'b1; wready = 1'b0;
    step(1);
    wvalid = 1'b0;
    expect_axil(axil_bit(`AXIL_P_W_VALID_HELD), "WVALID dropped");

    begin_scenario;
    bvalid = 1'b1; bready = 1'b0;
    step(1);
    bvalid = 1'b0;
    expect_axil(axil_bit(`AXIL_P_B_VALID_HELD), "BVALID dropped");

    begin_scenario;
    arvalid = 1'b1; arready = 1'b0; araddr = 32'h20;
    step(1);
    arvalid = 1'b0;
    expect_axil(axil_bit(`AXIL_P_AR_VALID_HELD), "ARVALID dropped");

    begin_scenario;
    rvalid = 1'b1; rready = 1'b0;
    step(1);
    rvalid = 1'b0;
    expect_axil(axil_bit(`AXIL_P_R_VALID_HELD), "RVALID dropped");

    // ---- A3.2.2  payload changed across a stalled handshake ----------------
    begin_scenario;
    awvalid = 1'b1; awready = 1'b0; awaddr = 32'h10;
    step(1);
    awaddr = 32'h20;              // VALID stays high, so only STABLE breaks
    step(1);
    awready = 1'b1;
    expect_axil(axil_bit(`AXIL_P_AW_STABLE), "AWADDR changed while stalled");

    begin_scenario;
    wvalid = 1'b1; wready = 1'b0; wdata = 32'h1111_1111;
    step(1);
    wdata = 32'h2222_2222;
    step(1);
    wready = 1'b1;
    expect_axil(axil_bit(`AXIL_P_W_STABLE), "WDATA changed while stalled");

    begin_scenario;
    earn_write_credit(32'h00);    // earn the response this scenario holds
    bvalid = 1'b1; bready = 1'b0; bresp = 2'b00;
    step(1);
    bresp = 2'b10;
    step(1);
    bready = 1'b1;
    expect_axil(axil_bit(`AXIL_P_B_STABLE), "BRESP changed while stalled");

    begin_scenario;
    arvalid = 1'b1; arready = 1'b0; araddr = 32'h20;
    step(1);
    araddr = 32'h30;
    step(1);
    arready = 1'b1;
    expect_axil(axil_bit(`AXIL_P_AR_STABLE), "ARADDR changed while stalled");

    begin_scenario;
    earn_read_credit(32'h00);
    rvalid = 1'b1; rready = 1'b0; rdata = 32'hAAAA_AAAA;
    step(1);
    rdata = 32'hBBBB_BBBB;
    step(1);
    rready = 1'b1;
    expect_axil(axil_bit(`AXIL_P_R_STABLE), "RDATA changed while stalled");

    // ---- A3.1.2  a VALID high during reset ---------------------------------
    begin_scenario;
    rst_n   = 1'b0;
    awvalid = 1'b1;
    step(2);
    awvalid = 1'b0;
    rst_n   = 1'b1;
    expect_axil(axil_bit(`AXIL_P_RESET_VALID_LOW), "AWVALID high in reset");

    // ---- A3.2.2  undriven payload under a live VALID -----------------------
    // AWREADY is high, so the beat is accepted and no stability or handshake
    // rule is in play: the only thing wrong is the x.
    begin_scenario;
    awaddr  = 'x; awvalid = 1'b1; awready = 1'b1;
    step(1);
    awvalid = 1'b0; awready = 1'b0;
    expect_axil(axil_bit(`AXIL_P_NO_X), "AWADDR x under AWVALID");

    // A narrow write with x in the lanes WSTRB does not select is legal, and
    // must not fire. This is the false-positive half of the NO_X property.
    begin_scenario;
    awaddr  = 32'h10; awvalid = 1'b1; awready = 1'b1;
    wdata   = {16'hxxxx, 16'hBEEF};
    wstrb   = 4'b0011; wvalid = 1'b1; wready = 1'b1;
    step(1);
    awvalid = 1'b0; awready = 1'b0; wvalid = 1'b0; wready = 1'b0;
    bresp   = 2'b00; bvalid = 1'b1; bready = 1'b1;
    step(1);
    bvalid  = 1'b0; bready = 1'b0;
    expect_axil('0, "x in unstrobed WDATA lanes is legal");

    // ---- B1.1.1  EXOKAY, which AXI4-Lite does not define -------------------
    begin_scenario;
    earn_write_credit(32'h00);
    bresp = 2'b01; bvalid = 1'b1; bready = 1'b1;
    step(1);
    bvalid = 1'b0; bready = 1'b0; bresp = 2'b00;
    expect_axil(axil_bit(`AXIL_P_RESP_LEGAL), "BRESP = EXOKAY");

    // ---- A3.3.1  a response nobody asked for -------------------------------
    begin_scenario;
    bvalid = 1'b1; bready = 1'b1; bresp = 2'b00;
    step(1);
    bvalid = 1'b0; bready = 1'b0;
    expect_axil(axil_bit(`AXIL_P_B_UNSOLICITED), "B without AW/W");

    begin_scenario;
    rvalid = 1'b1; rready = 1'b1; rresp = 2'b00; rdata = 32'h0;
    step(1);
    rvalid = 1'b0; rready = 1'b0;
    expect_axil(axil_bit(`AXIL_P_R_UNSOLICITED), "R without AR");

    // ---- B1.1  an unaligned address ----------------------------------------
    begin_scenario;
    awaddr  = 32'h0000_0001; awvalid = 1'b1; awready = 1'b1;
    step(1);
    awvalid = 1'b0; awready = 1'b0;
    expect_axil(axil_bit(`AXIL_P_ADDR_ALIGNED), "AWADDR unaligned");

    // ---- the control: legal traffic fires nothing --------------------------
    begin_scenario;
    legal_write(32'h10);
    legal_read(32'h14);
    legal_write(32'h18);
    expect_axil('0, "legal AXI4-Lite traffic");

    // ---------------------------------------------------------------------
    // AXI4-Stream
    // ---------------------------------------------------------------------

    // IHI0051 2.2.1  TVALID dropped before TREADY
    begin_scenario;
    tvalid = 1'b1; tready = 1'b0; tdata = 32'h1;
    step(1);
    tvalid = 1'b0;
    expect_axis(axis_bit(`AXIS_P_VALID_HELD), "TVALID dropped");

    // IHI0051 2.2.1  payload changed across a stalled handshake
    begin_scenario;
    tvalid = 1'b1; tready = 1'b0; tdata = 32'h1;
    step(1);
    tdata = 32'h2;
    step(1);
    tready = 1'b1;
    expect_axis(axis_bit(`AXIS_P_STABLE), "TDATA changed while stalled");

    // IHI0051 2.7  TVALID high during reset
    begin_scenario;
    rst_n  = 1'b0;
    tvalid = 1'b1;
    step(2);
    tvalid = 1'b0;
    rst_n  = 1'b1;
    expect_axis(axis_bit(`AXIS_P_RESET_VALID_LOW), "TVALID high in reset");

    // IHI0051 2.2  undriven payload under a live TVALID
    begin_scenario;
    tdata = 'x; tvalid = 1'b1; tready = 1'b1; tlast = 1'b0;
    step(1);
    tvalid = 1'b0; tready = 1'b0;
    expect_axis(axis_bit(`AXIS_P_NO_X), "TDATA x under TVALID");

    // R-IF-6  TLAST on the wrong beat: the packet is agreed to be four beats
    // and ends after two.
    begin_scenario;
    pkt_beats = 32'd4;
    tready = 1'b1;
    for (int i = 0; i < 2; i++) begin
      tdata  = i; tvalid = 1'b1; tlast = (i == 1);
      step(1);
    end
    tvalid = 1'b0; tlast = 1'b0; tready = 1'b0;
    expect_axis(axis_bit(`AXIS_P_PKT_LEN), "TLAST two beats early");

    // R-IF-6  a packet that runs past its agreed length with no TLAST
    begin_scenario;
    pkt_beats = 32'd4;
    tready = 1'b1;
    for (int i = 0; i < 6; i++) begin
      tdata  = i; tvalid = 1'b1; tlast = 1'b0;
      step(1);
    end
    tvalid = 1'b0; tready = 1'b0;
    expect_axis(axis_bit(`AXIS_P_PKT_LEN), "packet overran with no TLAST");

    // ---- the control: a correctly framed packet fires nothing --------------
    begin_scenario;
    pkt_beats = 32'd4;
    tready = 1'b1;
    for (int i = 0; i < 4; i++) begin
      tdata  = i; tvalid = 1'b1; tlast = (i == 3);
      step(1);
    end
    tvalid = 1'b0; tlast = 1'b0; tready = 1'b0;
    expect_axis('0, "a correctly framed 4-beat packet");

    // ---- and with stalls in it, which is the common real case --------------
    begin_scenario;
    pkt_beats = 32'd4;
    for (int i = 0; i < 4; i++) begin
      tdata  = i; tvalid = 1'b1; tlast = (i == 3); tready = 1'b0;
      step(2);                    // stall, payload held
      tready = 1'b1;
      step(1);
      tready = 1'b0;
    end
    tvalid = 1'b0; tlast = 1'b0;
    expect_axis('0, "a 4-beat packet with stalls");

    $display("");
    $display("%s  %0d checks, %0d failures",
             (n_fails == 0) ? "PASSED" : "FAILED", n_checks, n_fails);
    $display("");

    if (n_fails != 0) $fatal(1, "tb_vip_selftest failed");
    $finish;
  end

  // A scenario that never completes must report, not hang.
  initial begin
    #500us;
    $display("FAILED  watchdog expired, the self-test did not finish");
    $fatal(1, "tb_vip_selftest timeout");
  end

endmodule

// -----------------------------------------------------------------------------
// axis_monitor
//   Purpose      : Passive AXI4-Stream protocol monitor, used on both of the
//                  core's stream interfaces -- the read master and the write
//                  slave -- since the protocol rules are the same on either
//                  side of the handshake. It drives nothing.
//
//                  Beyond the IHI0051 handshake rules it also checks packet
//                  framing, which is where R-IF-6 lives: with PKT_BEATS set,
//                  TLAST must fall exactly on the last beat of every packet of
//                  that length, so an off-by-one tlast is a failure rather
//                  than a detail someone has to notice in a waveform.
//
//                  As in axi4_lite_monitor, each violation sets a sticky bit
//                  in `fired` so that tb_vip_selftest can prove the property
//                  detects its own violation.
//
//   Covers       : R-IF-5 (stream compliance), R-IF-6 (tlast correctness)
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "vip/vip_props.svh"

module axis_monitor #(
  parameter int    DATA_W    = 32,
  // Untyped, not `string`: Icarus 11 rejects a string-typed parameter.
  parameter        NAME      = "axis",
  parameter bit    QUIET_REPEAT = 1'b1,
  // The self-test commits violations on purpose and does not want them
  // printed; everyone else does.
  parameter bit    VERBOSE      = 1'b1
) (
  input logic              clk,
  input logic              rst_n,
  // Pulse high for one cycle to forget everything; see axi4_lite_monitor.
  input logic              clear_i,
  // Expected beats per packet, 0 to disable the framing checks. A port and not
  // a parameter because the agreed packet length is a property of the transfer
  // being run -- how many blocks were asked for, and whether the design frames
  // one packet per block or one per transfer -- which only the test knows.
  input logic [31:0]       pkt_beats_i,
  input logic [DATA_W-1:0] tdata,
  input logic              tvalid,
  input logic              tready,
  input logic              tlast
);

  int                   n_checks = 0;
  int                   n_viol   = 0;
  logic [`AXIS_NPROP-1:0] fired  = '0;

  int n_beats   = 0;  // beats accepted, all packets
  int n_packets = 0;  // TLAST handshakes seen
  int beat_in_pkt = 0;

  task automatic violation(input int prop, input string what);
    n_viol++;
    if (VERBOSE && !(QUIET_REPEAT && fired[prop]))
      $display("  VIOLATION [%s] p%0d %s  at %0t", NAME, prop, what, $time);
    fired[prop] = 1'b1;
  endtask

  task automatic armed(input int prop, input logic ok, input string what);
    n_checks++;
    if (!ok) violation(prop, what);
  endtask

  logic              p_rst_n = 1'b0;
  logic              p_tvalid = 1'b0, p_tready = 1'b0, p_tlast = 1'b0;
  logic [DATA_W-1:0] p_tdata  = '0;

  logic steady;
  assign steady = rst_n && p_rst_n;

  always @(posedge clk) begin

   if (clear_i) begin
    n_checks    = 0;
    n_viol      = 0;
    fired       = '0;
    n_beats     = 0;
    n_packets   = 0;
    beat_in_pkt = 0;
   end else begin

    // ---- IHI0051 2.7  TVALID low in reset ----------------------------------
    if (!rst_n)
      armed(`AXIS_P_RESET_VALID_LOW, !tvalid,
            "TVALID was high while rst_n was low");

    if (steady) begin
      // ---- IHI0051 2.2.1  TVALID held until TREADY -------------------------
      if (p_tvalid && !p_tready)
        armed(`AXIS_P_VALID_HELD, tvalid, "TVALID dropped before TREADY");

      // ---- IHI0051 2.2.1  payload stable across a stalled handshake --------
      if (p_tvalid && !p_tready && tvalid)
        armed(`AXIS_P_STABLE, (tdata === p_tdata) && (tlast === p_tlast),
              "TDATA/TLAST changed while TVALID was stalled");
    end

    if (rst_n) begin
      // ---- IHI0051 2.2  no undriven payload under a live TVALID ------------
      if (tvalid)
        armed(`AXIS_P_NO_X, !`VIP_HAS_X(tdata) && !`VIP_HAS_X(tlast),
              $sformatf("TDATA/TLAST has x/z while TVALID (tdata=%h tlast=%b)",
                        tdata, tlast));

      // ---- R-IF-6  packet framing ------------------------------------------
      if (tvalid && tready && !`VIP_HAS_X(tlast)) begin
        n_beats++;
        if (tlast) begin
          n_packets++;
          if (pkt_beats_i != 0)
            armed(`AXIS_P_PKT_LEN, (beat_in_pkt + 1) == int'(pkt_beats_i),
                  $sformatf("TLAST on beat %0d of a %0d-beat packet",
                            beat_in_pkt + 1, pkt_beats_i));
          beat_in_pkt = 0;
        end else begin
          beat_in_pkt++;
          // A packet that runs past its agreed length is as wrong as one that
          // ends early, and waiting for the TLAST that never comes would only
          // hang the test.
          if (pkt_beats_i != 0)
            armed(`AXIS_P_PKT_LEN, beat_in_pkt < int'(pkt_beats_i),
                  $sformatf("packet ran past its %0d agreed beats with no TLAST",
                            pkt_beats_i));
        end
      end
    end

   end

    p_rst_n  <= rst_n;
    p_tvalid <= tvalid; p_tready <= tready;
    p_tdata  <= tdata;  p_tlast  <= tlast;
  end

  // ---- end of test ----------------------------------------------------------
  // R-IF-6: a stream that stops mid-packet has not finished its transfer.
  task automatic check_drained;
    n_checks++;
    if (beat_in_pkt != 0)
      violation(`AXIS_P_DRAINED,
                $sformatf("ended %0d beats into an unterminated packet",
                          beat_in_pkt));
  endtask

  task automatic report;
    $display("  [%s] %0d beats in %0d packets, %0d armed checks, %0d violations",
             NAME, n_beats, n_packets, n_checks, n_viol);
  endtask

  task automatic clear;
    n_checks = 0;
    n_viol   = 0;
    fired    = '0;
    n_beats  = 0;
    n_packets = 0;
    beat_in_pkt = 0;
  endtask

endmodule

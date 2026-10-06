// -----------------------------------------------------------------------------
// Property indices, shared between each monitor and the self-test that proves
// the monitor fires. A monitor exposes a sticky `fired` bit vector; the
// self-test commits one violation at a time and asserts that exactly the
// expected bit went high. The indices therefore have to be nameable from both
// sides, which is what this file is for.
//
// Every property cites the clause it comes from:
//   IHI0022  AMBA AXI and ACE Protocol Specification (AXI4, AXI4-Lite)
//   IHI0051  AMBA 4 AXI4-Stream Protocol Specification
// -----------------------------------------------------------------------------
`ifndef VIP_PROPS_SVH
`define VIP_PROPS_SVH

// Is any bit of the expression x or z?
//
// Not $isunknown: under Icarus 11 that system function only answers correctly
// for a plain signal name. Given a part-select or a concatenation it returns 1
// unconditionally, which turns the "payload must be driven" properties into
// checks that fail on every legal beat. The XOR-reduction idiom is correct for
// all three forms -- reducing any x or z bit yields x -- so it is what the
// monitors use throughout.
`define VIP_HAS_X(v) ((^(v)) === 1'bx)

// ---- AXI4-Lite, axi4_lite_monitor -------------------------------------------
// A3.2.1  once VALID is asserted it must remain asserted until READY is high
`define AXIL_P_AW_VALID_HELD   0
`define AXIL_P_W_VALID_HELD    1
`define AXIL_P_B_VALID_HELD    2
`define AXIL_P_AR_VALID_HELD   3
`define AXIL_P_R_VALID_HELD    4
// A3.2.2  payload must not change while VALID is high and READY is low
`define AXIL_P_AW_STABLE       5
`define AXIL_P_W_STABLE        6
`define AXIL_P_B_STABLE        7
`define AXIL_P_AR_STABLE       8
`define AXIL_P_R_STABLE        9
// A3.1.2  VALID must be low while in reset and for the first cycle after it
`define AXIL_P_RESET_VALID_LOW 10
// A3.2.2  payload must be fully driven whenever VALID is high
`define AXIL_P_NO_X           11
// B1.1.1  AXI4-Lite supports OKAY and SLVERR/DECERR only -- never EXOKAY
`define AXIL_P_RESP_LEGAL     12
// A3.3.1  a response may not appear without the request that earned it
`define AXIL_P_B_UNSOLICITED  13
`define AXIL_P_R_UNSOLICITED  14
// B1.1    all AXI4-Lite accesses are aligned to the data bus width
`define AXIL_P_ADDR_ALIGNED   15
// A3.3.1  every accepted request is eventually answered: nothing left over
`define AXIL_P_DRAINED        16

`define AXIL_NPROP            17

// ---- AXI4-Stream, axis_monitor ----------------------------------------------
// IHI0051 2.2.1  TVALID must remain asserted until TREADY is high
`define AXIS_P_VALID_HELD      0
// IHI0051 2.2.1  payload must not change while TVALID is high and TREADY low
`define AXIS_P_STABLE          1
// IHI0051 2.7    TVALID must be low while in reset
`define AXIS_P_RESET_VALID_LOW 2
// IHI0051 2.2    payload must be fully driven whenever TVALID is high
`define AXIS_P_NO_X            3
// R-IF-6  TLAST marks the last beat of a packet of the agreed length
`define AXIS_P_PKT_LEN         4
// R-IF-6  a transfer ends on a TLAST: no half packet left behind
`define AXIS_P_DRAINED         5

`define AXIS_NPROP             6

`endif

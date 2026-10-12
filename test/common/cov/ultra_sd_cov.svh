// -----------------------------------------------------------------------------
// ultra_sd_cov.svh -- functional coverage collection, in plain SystemVerilog.
//
// WHY THERE IS NO `covergroup` IN HERE
//
// The simulators this project is verified on do not implement SystemVerilog
// functional coverage: Icarus has no covergroup at all, and Verilator's
// --coverage is line and toggle coverage, which answers a different question.
// Writing covergroups would mean either adding a commercial simulator to the
// toolchain -- Section 2.7 does not have one -- or writing coverage that never
// runs, which is worse than none because it looks like it does.
//
// So the bins are counters and the sampling is an always block. That costs the
// automatic cross products and the nice report, and it keeps the thing that
// actually matters: a machine-checkable statement of which states of the
// specification were reached, failing the build when a required one was not.
//
// WHAT IS COVERED, AND WHY THESE AND NOT OTHERS
//
// Four axes, each one a list the specification writes down, so the bins cannot
// drift into "whatever the design happens to do":
//
//   commands    Table 6-2, the minimum command set. Every row has to be issued
//               by something, or the design has a command it never uses and
//               the tests have a path they never take.
//   error codes Table 5-3. These are the hardest states to reach -- a real
//               card does not produce them on demand -- so an uncovered one
//               means the recovery path behind it has never executed.
//   bus / speed Table 7-1's observable outcomes: 1-bit and 4-bit, and all
//               three speed modes.
//   divisors    R-DEG-1 asks for 400 kHz, 25 MHz and 50 MHz plus intermediate
//               divisions, runtime-selectable. The bins are the divisor values
//               actually programmed.
//
// Include this in a testbench and instantiate it with the DUT's internals
// wired in; test/coverage/tb_coverage.sv is the one that drives it to closure.
// -----------------------------------------------------------------------------

// One bin table, so a testbench that only wants to observe can include this
// without taking the closure checks with it.
`ifndef ULTRA_SD_COV_SVH
`define ULTRA_SD_COV_SVH

// Table 6-2 plus the two the data layer adds. Index is the bin number, not the
// command index, so the report prints in specification order.
localparam int COV_N_CMD = 17;

function automatic string cov_cmd_name(input int i);
  case (i)
    0:  return "CMD0  GO_IDLE";
    1:  return "CMD2  ALL_SEND_CID";
    2:  return "CMD3  SEND_RCA";
    3:  return "CMD6  SWITCH_FUNC";
    4:  return "CMD7  SELECT_CARD";
    5:  return "CMD8  SEND_IF_COND";
    6:  return "CMD9  SEND_CSD";
    7:  return "CMD12 STOP_TRANS";
    8:  return "CMD13 SEND_STATUS";
    9:  return "CMD17 READ_SINGLE";
    10: return "CMD18 READ_MULTI";
    11: return "CMD24 WRITE_SINGLE";
    12: return "CMD25 WRITE_MULTI";
    13: return "CMD55 APP_CMD";
    14: return "ACMD6 SET_BUS_WIDTH";
    15: return "ACMD23 SET_WR_BLK_ERASE";
    16: return "ACMD41 SD_SEND_OP_COND";
    default: return "?";
  endcase
endfunction

// Maps an issued (index, is_acmd) pair onto a bin, or -1 for one this table
// does not track. ACMD51 is deliberately absent: it is issued as a normal
// command with the CMD55 prefix and is covered by bin 13 plus the SCR read.
function automatic int cov_cmd_bin(input logic [5:0] idx, input logic acmd);
  if (acmd) begin
    case (idx)
      6:  return 14;
      23: return 15;
      41: return 16;
      default: return -1;
    endcase
  end else begin
    case (idx)
      0:  return 0;
      2:  return 1;
      3:  return 2;
      6:  return 3;
      7:  return 4;
      8:  return 5;
      9:  return 6;
      12: return 7;
      13: return 8;
      17: return 9;
      18: return 10;
      24: return 11;
      25: return 12;
      55: return 13;
      default: return -1;
    endcase
  end
endfunction

localparam int COV_N_ERR = 13;   // Table 5-3, 0x00 .. 0x0C

function automatic string cov_err_name(input int i);
  case (i)
    0:  return "ERR_OK";
    1:  return "ERR_CMD_TIMEOUT";
    2:  return "ERR_CMD_CRC";
    3:  return "ERR_CMD_STATUS";
    4:  return "ERR_DAT_TIMEOUT";
    5:  return "ERR_DAT_CRC";
    6:  return "ERR_WR_CRC_TOKEN";
    7:  return "ERR_NO_CARD";
    8:  return "ERR_INIT";
    9:  return "ERR_UNSUPPORTED";
    10: return "ERR_RANGE";
    11: return "ERR_CARD_STATE";
    12: return "ERR_PROTOCOL";
    default: return "?";
  endcase
endfunction

`endif

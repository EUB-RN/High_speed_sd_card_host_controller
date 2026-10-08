// -----------------------------------------------------------------------------
// bench_defines.sv -- macros for the benchmark build, and nothing else.
//
// gw_sh has no -define option (set_option -help lists -include_path and
// -verilog_std and stops there), and passing one aborts the script before
// `run all` without touching the bitstream -- a build that looks like it worked
// and silently reprograms the previous one. GowinSynthesis compiles the added
// files as a single unit, so a `define in the first file reaches the rest.
//
// Added FIRST in build.tcl. Order is load-bearing here: a file listed after
// ultra_sd_cmd.sv would define the macro too late to change its port list.
// -----------------------------------------------------------------------------
`define ULTRA_SD_DEBUG_PORT 1

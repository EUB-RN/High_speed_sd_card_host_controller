// -----------------------------------------------------------------------------
// bench_defines_deg.sv -- macros for the R-DEG-7 degradation bitstream.
//
// Same mechanism and the same ordering rule as bench_defines.sv: gw_sh has no
// -define, GowinSynthesis compiles the added files as one unit, so a `define
// in the first file added reaches every file after it. This one is added
// INSTEAD of bench_defines.sv by build_deg.tcl.
//
// SUITE 5 is SUITE_DEG: the Section 7.4 graceful-degradation procedure. It
// forces the two fallbacks that cannot be exercised any other way on hardware
// -- CFG_PHY.FORCE_1BIT and CFG_PHY.FORCE_DS -- re-runs the initialisation
// ladder so the card agrees with the host about the bus width, checks that
// STATUS reports the mode actually negotiated rather than the one asked for
// (R-DEG-5), and then does real verified work in the degraded mode.
//
// The third fallback of Section 7.4, a reduced SD clock, is NOT here: the tier
// bitstream's characterisation sweep already verifies payload at five
// frequencies from 49.5 MHz down to 399 kHz, and repeating it would measure
// the same thing twice.
//
// SOAK_BLOCKS is reused as the size of the verified pair, because SUITE_DEG
// does one pair and has no need of a size parameter of its own. Eight blocks
// in 1-bit Default Speed is roughly eight times the duration of the same
// transfer in 4-bit High Speed, which is the point: it is enough work for a
// width or speed mismatch to corrupt rather than to get lucky.
// -----------------------------------------------------------------------------
`define ULTRA_SD_DEBUG_PORT 1
`define BENCH_SUITE 5
`define BENCH_SOAK_BLOCKS 8

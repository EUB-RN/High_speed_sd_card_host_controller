// -----------------------------------------------------------------------------
// bench_defines_soak.sv -- macros for the R-MEAS-5 soak bitstream.
//
// Same mechanism and the same ordering rule as bench_defines.sv: gw_sh has no
// -define, GowinSynthesis compiles the added files as one unit, so a `define
// in the first file added reaches every file after it. This one is added
// INSTEAD of bench_defines.sv by build_soak.tcl.
//
// SUITE 4 is SUITE_SOAK: one verified write / read-back pair per iteration,
// forever, with the mismatch count, the retry count and the R-IF-11 counter
// cross-check reported at the end. That is exactly the procedure R-MEAS-5
// asks for -- "alternating write and read-back continuously for 30 minutes,
// zero unrecovered errors" -- and it is the one thing the tier bitstream
// deliberately does not do.
//
// ITERATION COUNT. One 8-block pair is roughly a millisecond at the tier
// divisor, dominated by the card's per-transfer access and programming cost
// rather than by payload, so half an hour is of order 1.8 million pairs. The
// number below is set from a measured short run rather than from that
// estimate -- see doc/report.md for the measurement and the arithmetic.
// -----------------------------------------------------------------------------
`define ULTRA_SD_DEBUG_PORT 1
`define BENCH_SUITE 4
`define BENCH_SOAK_ITERS 185000
`define BENCH_SOAK_BLOCKS 8

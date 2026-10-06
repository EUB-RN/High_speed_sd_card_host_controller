# Performance verification. Not "does it work" but "does it meet the number":
# sustained throughput measured in the testbench, bus efficiency, and the
# statistics counters of R-IF-11 cross-checked against what the testbench
# itself counted. The characterisation sweep across SD clock frequency
# (Section 7.4, R-MEAS-6) lives here too, so the simulated numbers can be
# compared against the hardware runs in reports/.
#
# Measured numbers go to reports/, not just to the log, and the test fails if
# throughput drops below its floor -- a performance test that only prints is a
# performance test nobody reads.

performance_TESTS :=

# Still to write here:
#   throughput_read      sustained CMD18 streaming, MB/s with no stalling
#   throughput_write     sustained CMD25 streaming
#   counter_crosscheck   the five statistics counters against testbench counts
#   freq_sweep           400 kHz .. 50 MHz characterisation table

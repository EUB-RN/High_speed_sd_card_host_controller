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

performance_TESTS := throughput_read throughput_write counter_crosscheck freq_sweep

# Where a multi-block read's non-payload SD cycles go, against the behavioural
# card -- which has no flash, so whatever it finds is the host's.
throughput_read_DEFS := ULTRA_SD_NO_VENDOR_PRIM
throughput_read_SRCS := $(PKG) \
                        $(RTL_DIR)/crc/ultra_sd_crc7.sv \
                        $(RTL_DIR)/crc/ultra_sd_crc16.sv \
                        $(RTL_DIR)/clk_controller.sv \
                        $(RTL_DIR)/rst_sync.sv \
                        $(RTL_DIR)/system_controller.sv \
                        $(RTL_DIR)/axi4/async_fifo.sv \
                        $(RTL_DIR)/axi4/axi4_lite_slave.sv \
                        $(RTL_DIR)/axi4/axis_rd_master.sv \
                        $(RTL_DIR)/axi4/axis_wr_slave.sv \
                        $(RTL_DIR)/axi4/ultra_sd_axi_top.sv \
                        $(RTL_DIR)/ultra_sd_reg.sv \
                        $(RTL_DIR)/ultra_sd_block.sv \
                        $(RTL_DIR)/ultra_sd_cmd.sv \
                        $(RTL_DIR)/ultra_sd_cmd_tx.sv \
                        $(RTL_DIR)/ultra_sd_init.sv \
                        $(RTL_DIR)/ultra_sd_protocol.sv \
                        $(RTL_DIR)/ultra_sd_line.sv \
                        $(RTL_DIR)/ultra_sd_phy_gowin.sv \
                        $(RTL_DIR)/ultra_sd_top.sv \
                        $(TEST_DIR)/common/models/sd_card_model.sv \
                        $(TEST_DIR)/performance/tb_throughput_read.sv

# The write side of the same accounting, plus the R-PERF-5 gate: the card's
# programming time is subtracted the way Section 12.4 subtracts it, and what is
# left -- the host's own share -- has to clear 85%.
throughput_write_DEFS := $(throughput_read_DEFS)
throughput_write_SRCS := $(subst tb_throughput_read.sv,tb_throughput_write.sv,$(throughput_read_SRCS))

# R-IF-11: every Table 5-2 counter against a second, independent count of the
# same event, with the retry halves forced non-zero by injection -- a counter
# that never increments agrees with a testbench that never saw an increment.
counter_crosscheck_DEFS := $(throughput_read_DEFS)
counter_crosscheck_SRCS := $(subst tb_throughput_read.sv,tb_counter_crosscheck.sv,$(throughput_read_SRCS))

# R-MEAS-6's sweep, as the part of it a simulation can actually establish:
# that CFG_CLK is the only variable -- same payload, same SD-cycle cost, and
# system-clock time in proportion to the divisor. The absolute rate-vs-MHz
# table is a hardware measurement and lives in reports/.
freq_sweep_DEFS := $(throughput_read_DEFS)
freq_sweep_SRCS := $(subst tb_throughput_read.sv,tb_freq_sweep.sv,$(throughput_read_SRCS))

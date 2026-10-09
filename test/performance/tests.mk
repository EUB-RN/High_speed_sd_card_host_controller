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

performance_TESTS := throughput_read

# Where a multi-block read's non-payload SD cycles go, against the behavioural
# card -- which has no flash, so whatever it finds is the host's.
throughput_read_DEFS := ULTRA_SD_NO_VENDOR_PRIM
throughput_read_SRCS := $(PKG) \
                        $(RTL_DIR)/crc/ultra_sd_crc7.sv \
                        $(RTL_DIR)/crc/ultra_sd_crc16.sv \
                        $(RTL_DIR)/clk_controller.sv \
                        $(RTL_DIR)/system_controller.sv \
                        $(RTL_DIR)/axi4/async_fifo.sv \
                        $(RTL_DIR)/axi4/axi4_lite_slave.sv \
                        $(RTL_DIR)/axi4/axis_rd_master.sv \
                        $(RTL_DIR)/axi4/axis_wr_slave.sv \
                        $(RTL_DIR)/axi4/ultra_sd_axi_top.sv \
                        $(RTL_DIR)/ultra_sd_reg.sv \
                        $(RTL_DIR)/ultra_sd_block.sv \
                        $(RTL_DIR)/ultra_sd_cmd.sv \
                        $(RTL_DIR)/ultra_sd_line.sv \
                        $(RTL_DIR)/ultra_sd_phy_gowin.sv \
                        $(RTL_DIR)/ultra_sd_top.sv \
                        $(TEST_DIR)/common/models/sd_card_model.sv \
                        $(TEST_DIR)/performance/tb_throughput_read.sv

# Still to write here:
#   throughput_write     sustained CMD25 streaming
#   counter_crosscheck   the five statistics counters against testbench counts
#   freq_sweep           400 kHz .. 50 MHz characterisation table

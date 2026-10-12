# Stress and soak. Long, randomised, deliberately hostile: random
# backpressure and starvation patterns on both streams, randomised block
# counts and LBAs, and several hundred transfers back to back with no reset
# between them. Reproducibility comes from the seed, so every failure is
# replayable with `make random_traffic SEED=<n>`.
#
# WHY THESE ARE IN THE DEFAULT REGRESSION AND THE SOAK IS NOT
#
# random_traffic at its default 200 transfers runs in about a minute, which is
# worth paying on every commit: it is the only test that asks the core to do
# several hundred different things in a row without being reset, and ordering
# bugs do not show up any other way. The 30-minute R-MEAS-5 soak is a hardware
# procedure (reports/uart_soak.log) and a nightly simulation target, not a
# pre-commit gate -- see soak_long below.

stress_TESTS := random_traffic

# Seeded random read/write mix, scoreboard-checked.
#
# The scoreboard is the part worth defending. The obvious version of this test
# writes a counting pattern and checks it comes back, which catches corruption
# but not DISPLACEMENT: a read that returns the right bytes from the wrong LBA
# passes it, and so does a write that lands one block early. This one keeps its
# own copy of every block it has written and compares reads against that, so
# the L3 address arithmetic is under test as well as the payload.
#
# Backpressure and starvation percentages are re-rolled per transfer, from 0 to
# 90 %. The directed tests all run the streams at full rate, so this is the only
# place R-IF-7's "arbitrary" and R-IF-8's "arbitrarily slow" are taken literally.
random_traffic_DEFS := ULTRA_SD_NO_VENDOR_PRIM
random_traffic_SRCS := $(PKG) \
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
                       $(TEST_DIR)/stress/tb_random_traffic.sv

# The nightly: the same testbench with a much larger transfer count. Not a
# separate file, because a soak that drifts from the test it is soaking proves
# nothing about it.
#
#   make soak_long            2000 transfers, random seed each night
#   make soak_long SEED=1234  replay
.PHONY: soak_long
soak_long: random_traffic_LONG = 1
soak_long:
	@$(MAKE) --no-print-directory -C $(TEST_DIR) random_traffic \
	  PLUSARGS="+xfers=2000 $(if $(SEED),+seed=$(SEED),)"

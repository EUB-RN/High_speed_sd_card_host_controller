# Coverage closure. Functional coverage says which of the specification's
# states were actually exercised; without it a green regression only proves
# that whatever ran, passed.
#
# The bins and the reason they are counters rather than covergroups are in
# test/common/cov/ultra_sd_cov.svh: neither simulator in Section 2.7's
# toolchain implements SystemVerilog functional coverage, and coverage that
# cannot run is worse than none because it looks like it does.
#
# This category is a RATCHET, not a report. tb_coverage fails when a bin the
# specification requires was not reached, so the required list only ever grows.

coverage_TESTS := coverage

# Drives the four lists the specification writes down to closure: Table 6-2's
# command set, the reachable half of Table 5-3's error codes, Table 7-1's bus
# and speed outcomes, and four points of R-DEG-1's divisor range. The error
# codes are the expensive part -- a healthy card produces none of them -- so
# the test spends most of its time in the card model's fault injectors.
#
# Five Table 5-3 codes are deliberately NOT required, and tb_coverage names
# each one and why: ERR_CMD_CRC, ERR_CMD_STATUS, ERR_INIT, ERR_UNSUPPORTED and
# ERR_CARD_STATE all need card behaviour sd_card_model does not implement.
# Reaching them is model work and it is the next thing this directory wants.
coverage_DEFS := ULTRA_SD_NO_VENDOR_PRIM
coverage_SRCS := $(PKG) \
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
                 $(TEST_DIR)/coverage/tb_coverage.sv

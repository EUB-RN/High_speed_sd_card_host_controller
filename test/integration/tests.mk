# Multi-block integration tests. These instantiate real adjacent RTL layers;
# behavioural code stands in only for the SD card or host outside the core.

integration_TESTS := init_cmd_stack block_stat block_axis_read block_axis_write \
                     line_card top_integration bench_flow

# The seam between u_line and the card model: tb_ultra_sd_line drives u_line from
# stimulus written beside it, tb_sd_card_model drives the card from a real
# ultra_sd_cmd with no u_line in it at all, so until this test the two ends had
# never been connected to each other.
#
# REGISTERED AND CURRENTLY RED: 11 of 151 checks fail. It arrived with 645e7db
# and was never added to this list, so it had never reported anything. Listed
# now because a test that does not run cannot report, and what it reports is
# this, identically with and without LINE_CARD_WITH_PHY:
#
#   1/5 SCR 8B 1-bit        received 0 of 2 payload words
#   2/5 SWITCH 64B 1-bit    received 2 of 16 payload words
#   3/5 BLOCK 512B 1-bit    passes
#   4/5 BLOCK 512B 4-bit    received 0 of 128 payload words
#   5/5 WRITE 512B 4-bit    byte 0 expected 5a got a5, card storage mismatch
#
# Not yet root-caused, and the direction matters before anyone trusts it: the
# same 4-bit 512-byte path is green in tb_bench_flow, in tb_top_integration and
# on hardware (MISMATCH = 0 over 64 MB), so the first thing to rule out is this
# testbench's own bit-banged ACMD6 leaving the card model in 1-bit while u_line
# transfers in 4-bit -- which is what both a nibble-swapped write byte and a
# read that lands nothing would look like.
line_card_DEFS := ULTRA_SD_NO_VENDOR_PRIM
line_card_SRCS := $(PKG) \
                  $(RTL_DIR)/crc/ultra_sd_crc7.sv \
                  $(RTL_DIR)/crc/ultra_sd_crc16.sv \
                  $(RTL_DIR)/clk_controller.sv \
                  $(RTL_DIR)/ultra_sd_phy_gowin.sv \
                  $(RTL_DIR)/ultra_sd_line.sv \
                  $(TEST_DIR)/common/models/sd_card_model.sv \
                  $(TEST_DIR)/integration/tb_line_card.sv

init_cmd_stack_SRCS := $(PKG) $(RTL_DIR)/crc/ultra_sd_crc7.sv \
                       $(RTL_DIR)/ultra_sd_cmd.sv \
                       $(TEST_DIR)/integration/tb_init_cmd_stack.sv

# Table 5-1 / Table 5-2 artik system_controller'in icinde: bu test L3'u o
# modulun durum/sayac bolumuyle birlikte kosar.
block_stat_SRCS := $(PKG) $(RTL_DIR)/ultra_sd_block.sv \
                   $(RTL_DIR)/system_controller.sv \
                   $(TEST_DIR)/integration/tb_block_stat.sv

block_axis_read_SRCS := $(PKG) $(RTL_DIR)/axi4/async_fifo.sv \
                        $(RTL_DIR)/axi4/axis_rd_master.sv \
                        $(RTL_DIR)/ultra_sd_block.sv \
                        $(TEST_DIR)/integration/tb_block_axis_read.sv

block_axis_write_SRCS := $(PKG) $(RTL_DIR)/axi4/async_fifo.sv \
                         $(RTL_DIR)/axi4/axis_wr_slave.sv \
                         $(RTL_DIR)/ultra_sd_block.sv \
                         $(TEST_DIR)/integration/tb_block_axis_write.sv

top_integration_DEFS := ULTRA_SD_NO_VENDOR_PRIM
top_integration_SRCS := $(PKG) \
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
                        $(TEST_DIR)/integration/tb_top_integration.sv

# The benchmark wrapper, against the behavioural card. bench/ is not part of the
# delivered core -- it is the measurement harness we use to get numbers before the
# client's harness ever sees the design (Section 12.1) -- but it produces every
# figure in the report, so it is verified here like any other RTL.
bench_flow_DEFS := ULTRA_SD_NO_VENDOR_PRIM ULTRA_SD_DEBUG_PORT
bench_flow_SRCS := $(PKG) \
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
                   $(BENCH_DIR)/bench_uart_tx.sv \
                   $(BENCH_DIR)/bench_lfsr.sv \
                   $(BENCH_DIR)/bench_div.sv \
                   $(BENCH_DIR)/bench_axil_master.sv \
                   $(BENCH_DIR)/bench_report.sv \
                   $(BENCH_DIR)/bench_core.sv \
                   $(TEST_DIR)/common/models/sd_card_model.sv \
                   $(TEST_DIR)/integration/tb_bench_flow.sv

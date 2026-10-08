# Multi-block integration tests. These instantiate real adjacent RTL layers;
# behavioural code stands in only for the SD card or host outside the core.

integration_TESTS := init_cmd_stack block_stat block_axis_read block_axis_write \
                     top_integration bench_flow

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

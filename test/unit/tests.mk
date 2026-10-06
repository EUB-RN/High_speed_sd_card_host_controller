# Unit tests: one module against its own contract, no protocol stack above it.
# A unit test may use the common/ checker macros but drives the DUT's ports
# directly.

unit_TESTS := clk_controller

clk_controller_SRCS := $(PKG) $(RTL_DIR)/clk_controller.sv \
                       $(TEST_DIR)/unit/tb_clk_controller.sv

# Still to write here:
#   system_controller  reset sequencing, the 74-clock ramp gate
#   ultra_sd_reg       Table 5-1 field behaviour at the simple wr_en/rd_en bus
#   ultra_sd_crc7 / ultra_sd_crc16   against known-answer vectors
#   async_fifo         gray-pointer crossing, full/empty, both directions

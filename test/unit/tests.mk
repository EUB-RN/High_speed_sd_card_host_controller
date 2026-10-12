# Unit tests: one module against its own contract, no protocol stack above it.
# A unit test may use the common/ checker macros but drives the DUT's ports
# directly.

unit_TESTS := clk_controller phy_clk_gate crc7 crc16 ultra_sd_reg async_fifo ultra_sd_cmd \
              system_controller

clk_controller_SRCS := $(PKG) $(RTL_DIR)/clk_controller.sv \
                       $(TEST_DIR)/unit/tb_clk_controller.sv

# PHY'nin saat sozlesmesi: gateleme (DQCE) ve ped mux'u (DCS). Satici
# primitifleri yerine davranissal modelleri kosar.
phy_clk_gate_SRCS := $(PKG) $(RTL_DIR)/clk_controller.sv \
                     $(RTL_DIR)/ultra_sd_phy_gowin.sv \
                     $(TEST_DIR)/unit/tb_phy_clk_gate.sv
phy_clk_gate_DEFS := ULTRA_SD_NO_VENDOR_PRIM

crc7_SRCS := $(PKG) $(RTL_DIR)/crc/ultra_sd_crc7.sv \
             $(TEST_DIR)/unit/tb_crc7.sv

crc16_SRCS := $(PKG) $(RTL_DIR)/crc/ultra_sd_crc16.sv \
              $(TEST_DIR)/unit/tb_crc16.sv

ultra_sd_reg_SRCS := $(PKG) $(RTL_DIR)/ultra_sd_reg.sv \
                     $(TEST_DIR)/unit/tb_ultra_sd_reg.sv

async_fifo_SRCS := $(RTL_DIR)/axi4/async_fifo.sv \
                   $(TEST_DIR)/unit/tb_async_fifo.sv

ultra_sd_cmd_SRCS := $(PKG) $(RTL_DIR)/crc/ultra_sd_crc7.sv \
                     $(RTL_DIR)/ultra_sd_cmd.sv \
                     $(RTL_DIR)/ultra_sd_cmd_tx.sv \
                     $(RTL_DIR)/ultra_sd_init.sv \
                     $(RTL_DIR)/ultra_sd_protocol.sv \
                     $(TEST_DIR)/unit/tb_ultra_sd_cmd.sv

system_controller_SRCS := $(PKG) $(RTL_DIR)/rst_sync.sv $(RTL_DIR)/system_controller.sv \
                          $(TEST_DIR)/unit/tb_system_controller.sv

# Still to write here:

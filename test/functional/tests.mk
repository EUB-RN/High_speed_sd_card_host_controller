# Functional tests: end-to-end scenarios against a behavioural SD card model,
# written in the language of the specification rather than of the RTL. These
# are the R-DEL-6 required scenarios.

functional_TESTS := ultra_sd_line init_ladder_basic init_ladder_full block_requests block_flow

# DAT hatti cerceveleme: yazma / okuma / CRC16 / CRC durum token'i, davranissal
# bir kart modeline karsi.
ultra_sd_line_SRCS := $(PKG) $(RTL_DIR)/crc/ultra_sd_crc16.sv \
                      $(RTL_DIR)/ultra_sd_line.sv \
                      $(TEST_DIR)/functional/tb_ultra_sd_line.sv

# Separate init and command modules are tested through the protocol wrapper.
init_ladder_basic_SRCS := $(PKG) $(RTL_DIR)/crc/ultra_sd_crc7.sv \
                          $(RTL_DIR)/ultra_sd_cmd.sv \
                          $(RTL_DIR)/ultra_sd_cmd_tx.sv \
                          $(RTL_DIR)/ultra_sd_init.sv \
                          $(RTL_DIR)/ultra_sd_protocol.sv \
                          $(TEST_DIR)/functional/tb_init_ladder_basic.sv

init_ladder_full_SRCS := $(PKG) $(RTL_DIR)/crc/ultra_sd_crc7.sv \
                         $(RTL_DIR)/ultra_sd_cmd.sv \
                         $(RTL_DIR)/ultra_sd_cmd_tx.sv \
                         $(RTL_DIR)/ultra_sd_init.sv \
                         $(RTL_DIR)/ultra_sd_protocol.sv \
                         $(TEST_DIR)/functional/tb_init_ladder_full.sv

block_requests_SRCS := $(PKG) $(RTL_DIR)/ultra_sd_block.sv \
                       $(TEST_DIR)/functional/tb_block_requests.sv

block_flow_SRCS := $(PKG) $(RTL_DIR)/ultra_sd_block.sv \
                   $(TEST_DIR)/functional/tb_block_flow.sv

# Still to write here (R-DEL-6):
#   hs_switch          CMD6 High Speed switch, verified by status block read-back
#   sdsc_reject        SDSC detected and rejected, not silently mishandled
#   read_multi_payload end-to-end with the AXI FIFO and tlast
#   write_multi_payload end-to-end with the AXI FIFO and tlast
#   bus_width          4-bit operation (ACMD6)
#   card_detect        active-low card detect, insert and remove mid-transfer
#   error_recovery     recovery without full re-initialisation (R-FUNC-16)
#   timeouts           every wait bounded by its named timeout (R-FUNC-17)
#   degradation        the Table 7-1 fallback ladder, Section 7.4 procedure

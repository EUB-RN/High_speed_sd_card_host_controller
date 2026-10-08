# Multi-block integration tests. These instantiate real adjacent RTL layers;
# behavioural code stands in only for the SD card or host outside the core.

integration_TESTS := init_cmd_stack block_stat block_axis_read block_axis_write \
                     line_card top_integration bench_flow bench_timing

# The seam between u_line and the card model: tb_ultra_sd_line drives u_line from
# stimulus written beside it, tb_sd_card_model drives the card from a real
# ultra_sd_cmd with no u_line in it at all, so until this test the two ends had
# never been connected to each other.
#
# It arrived with 645e7db and was never added to this list, so it had never
# reported anything. Listed now, and green -- but it was red when first run, with
# 11 of 151 checks failing, and all three causes were in the test rather than in
# ultra_sd_line:
#
#   send_cmd returned four SD clocks after the command frame without waiting for
#   the card's response, so send_acmd's second command was driven onto CMD while
#   the card was still answering CMD55. Both ends drove a tri1, the card's own
#   receiver saw a malformed frame, set protocol_error_o and decoded nothing.
#
#   do_read sent the command and armed the engine afterwards. The card starts the
#   data frame NAC cycles after its response and does not wait, so the receiver
#   raced it for the start bit and lost -- in 4-bit, where the frame is four
#   times shorter in cycles. ultra_sd_block gets this right by construction:
#   S_RD_ARM raises dat_start_o and only then S_CMD issues the read.
#
#   do_write advanced its source word on every tx_take, including the one
#   ultra_sd_line raises during the start-bit cell to LOAD the first word. Every
#   word shifted by one; the CRC16 was computed over what was really sent so the
#   card accepted the block, and only the comparison against card storage showed
#   it. ultra_sd_block avoids it with wr_en_o = (step_q == S_WR_DATA) && tx_take_i.
#
# Two of the three were masked by the first: nothing reached the 4-bit path at
# all until the command collision was fixed.
#
# +lcdbg traces the card's DAT driver state against the engine's cell state,
# +lcnib the raw nibbles of the first cycles of a frame. Both are what found the
# above, and neither costs anything left in.
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

# The phase margin matrix (bench_core SUITE = 1) against the same card model.
# Same sources as bench_flow minus the debug port, which the matrix does not read.
bench_timing_DEFS := ULTRA_SD_NO_VENDOR_PRIM
bench_timing_SRCS := $(filter-out $(TEST_DIR)/integration/tb_bench_flow.sv,$(bench_flow_SRCS)) \
                     $(TEST_DIR)/integration/tb_bench_timing.sv

# The edge-case suite (bench_core SUITE = 2): transfer shapes, payload patterns,
# arguments that must be refused, and boundaries.
#
# NOT IN integration_TESTS YET, and deliberately: it currently reports 9 of 34
# checks failing and the cause is not yet known. What it HAS established:
#
#   SHAPE 0..4   pass. 1, 2, 3, 7 and 4 blocks all transfer and verify.
#   NEG  10..14  pass, with the exact codes: ERR_PROTOCOL (0x0C) for blocks = 0
#                in both directions, ERR_RANGE (0x0A) for all three ways of
#                running off the end. The refusal path is correct.
#   PATRN 5..9   fail -- but NOT because of the patterns. Running all twenty
#                cases on the LFSR alone reproduces the identical five failures,
#                and case 18 is parameter-for-parameter identical to case 4,
#                which passes. The failure follows POSITION, not content: every
#                case from the eleventh transfer on misbehaves.
#
# So there is a real finding here, it just is not the one the group names
# suggest. Root-cause it before listing the suite; a red regression that nobody
# can act on is worse than a suite that is honest about not being ready.
# Run it with: make bench_edge
bench_edge_DEFS := ULTRA_SD_NO_VENDOR_PRIM
bench_edge_SRCS := $(filter-out $(TEST_DIR)/integration/tb_bench_flow.sv,$(bench_flow_SRCS)) \
                   $(TEST_DIR)/integration/tb_bench_edge.sv

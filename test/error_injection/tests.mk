# Error- and fault-injection tests. Two distinct jobs, both living here:
#
#   1. Injecting errors into the *environment* -- a card that corrupts CRC,
#      drops a response, returns a bad status token -- and checking that the
#      design recovers as specified. This is design verification.
#
#   2. Injecting faults into the *design* and checking that the testbench
#      notices (R-DEL-7, Appendix E.4). This is verification of the
#      verification, and the client does exactly this to the delivery. Each
#      mutation is applied to a copy of the RTL under build/, never in place.
#
# Run it with `make error_injection`; mutation runs expect to FAIL the
# testbench, so the pass criterion is inverted and owned by the script.

error_injection_TESTS :=

# DRAFT, not in the regression yet. One of the four scenarios is verified; the
# other three reached behaviour nobody has characterised before, because nothing
# ever drove these paths:
#
#   crc16_read_error   PASSES. A persistently corrupted data CRC makes the core
#                      retry three times and then report ERR_DAT_CRC (0x05), and
#                      STAT_RETRY confirms the retries really happened. Removing
#                      the fault gives a clean read again. This one is done.
#
#   crc_status_reject  OPEN. A 2-block write whose first block the card rejects
#                      stalls at beat 226 of 256 and never reaches DONE. The
#                      retry has to rewind the payload FIFO and re-send; what it
#                      does instead is not yet known.
#
#   response_timeout   OPEN. The code is right -- ERR_CMD_TIMEOUT (0x01) -- but
#                      the transfer does not finish cleanly afterwards.
#
#   dat_stuck_busy     OPEN, blocked behind the write path above.
#
# A testbench bug found on the way, and worth knowing for any new test here:
# STATUS.DONE is cleared by accept_i, and `go` reaches ultra_sd_block through a
# two-flop synchroniser into cmd_clk -- twenty system clocks per edge at the
# tier divisor. A poll that starts right after the START write reads the
# PREVIOUS transfer's DONE and its error code. Wait for DONE to CLEAR first.
# bench_core never trips on this because X_RUN streams the payload before it
# polls. tb_error_inject now waits for both edges.
error_injection_DRAFTS := error_inject

# The four faults in one testbench rather than four: they share the whole
# harness -- core, card, AXI-Lite master, stream -- and differ by one input and
# one expected code, so four files would be four copies of the setup and one
# line of test each. Each scenario is named for the entry it covers below.
error_inject_DEFS := ULTRA_SD_NO_VENDOR_PRIM
error_inject_SRCS := $(PKG) \
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
                     $(TEST_DIR)/error_injection/tb_error_inject.sv

# Still to write here:
#   crc16_read_error     corrupt a read block, expect retry then CRC_RETRIES
#                        exhaustion and the Table 5-3 error code
#   crc_status_reject    card returns a write CRC status token of "rejected"
#   response_timeout     card never answers, expect the named timeout
#   dat_stuck_busy       card holds DAT0 low past the busy timeout
#   mutation.sh          the Appendix E.4 fault list, one mutation at a time

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

error_injection_TESTS := error_inject

# All four scenarios reach their Table 5-3 code and recover. Three of them were
# recorded here as OPEN for a long time, and the reason turned out to be the
# same single line in the testbench rather than three separate design problems:
#
#   crc16_read_error   a persistently corrupted data CRC makes the core retry
#                      CRC_RETRIES times and then report ERR_DAT_CRC (0x05),
#                      with STAT_RETRY confirming the retries happened.
#   crc_status_reject  a card that answers a written block with a negative CRC
#                      status token gets the block re-sent from the FIFO, and
#                      when it keeps refusing, ERR_WR_CRC_TOKEN (0x06). This is
#                      R-FUNC-13, and until now nothing had ever driven it.
#   response_timeout   a card that never answers gives ERR_CMD_TIMEOUT (0x01)
#                      out of ultra_sd_cmd's own retry ladder.
#   dat_stuck_busy     a card that never releases DAT0 gives ERR_DAT_TIMEOUT
#                      (0x04) when PROG_TIMEOUT_CLK expires.
#
# WHAT WAS ACTUALLY WRONG, since the notes that used to be here blamed the core:
#
#   The testbench armed its write source with wr_load, waited `@(posedge clk)`,
#   then cleared it -- which races the always_ff meant to sample it, and Icarus
#   resolved that race against the testbench every single time. wr_left was
#   never loaded, so no write scenario ever put a byte on the bus; the block
#   layer sat in S_WR_ARM waiting for a block nobody was sending. That is the
#   "stalls at beat 226 of 256 and never reaches DONE" this file used to
#   describe. crc16_read_error was unaffected only because a read passes
#   wr_req = 0. wr_load is driven on the negedge now.
#
# The scenarios did then find one real design bug, and it is worth knowing:
# S_BUSY was reading card_busy_i in the cycles before ultra_sd_line had sampled
# DAT0 at all, so a write could be reported DONE while the card was still
# programming. ultra_sd_block now has a settling delay before it believes that
# signal -- see BUSY_SETTLE there.
#
# The four faults share one harness -- core, card, AXI-Lite master, stream --
# and differ by one input and one expected code, so four files would be four
# copies of the setup and one line of test each.
#
# A testbench trap worth keeping: STATUS.DONE is cleared by accept_i, and `go`
# reaches ultra_sd_block through a two-flop synchroniser into the SD domain --
# twenty system clocks per edge at the tier divisor. A poll that starts right
# after the START write reads the PREVIOUS transfer's DONE and its error code.
# Wait for DONE to CLEAR first; xfer() does.
#
# +eidbg prints the block step, the line cell and the card's DAT state on
# change, which is what placed both of the bugs above.

error_inject_DEFS := ULTRA_SD_NO_VENDOR_PRIM
error_inject_SRCS := $(PKG) \
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
                     $(TEST_DIR)/error_injection/tb_error_inject.sv

# Still to write here:
#   crc16_read_error     corrupt a read block, expect retry then CRC_RETRIES
#                        exhaustion and the Table 5-3 error code
#   crc_status_reject    card returns a write CRC status token of "rejected"
#   response_timeout     card never answers, expect the named timeout
#   dat_stuck_busy       card holds DAT0 low past the busy timeout
#   mutation.sh          the Appendix E.4 fault list, one mutation at a time

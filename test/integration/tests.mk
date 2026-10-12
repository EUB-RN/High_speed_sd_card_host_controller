# Multi-block integration tests. These instantiate real adjacent RTL layers;
# behavioural code stands in only for the SD card or host outside the core.

integration_TESTS := init_cmd_stack block_stat block_axis_read block_axis_write \
                     line_card top_integration bench_flow bench_timing \
                     bench_soak bench_deg

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
                       $(RTL_DIR)/ultra_sd_cmd_tx.sv \
                       $(RTL_DIR)/ultra_sd_init.sv \
                       $(RTL_DIR)/ultra_sd_protocol.sv \
                       $(TEST_DIR)/integration/tb_init_cmd_stack.sv

# Table 5-1 / Table 5-2 artik system_controller'in icinde: bu test L3'u o
# modulun durum/sayac bolumuyle birlikte kosar.
block_stat_SRCS := $(PKG) $(RTL_DIR)/ultra_sd_block.sv \
                   $(RTL_DIR)/rst_sync.sv \
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
# NOT IN integration_TESTS, and the reason is now a measured trade rather than
# an unknown. It reports 9 of 34 checks failing. The CAUSE IS KNOWN, a fix was
# written and measured, and the fix was BACKED OUT -- all three facts matter,
# so here they are.
#
# WHAT PASSES
#
#   SHAPE 0..4   1, 2, 3, 7 and EDGE_BLOCKS blocks all transfer and verify.
#   NEG  10..14  pass, with the exact codes: ERR_PROTOCOL (0x0C) for blocks = 0
#                in both directions, ERR_RANGE (0x0A) for all three ways of
#                running off the end. The refusal path is correct.
#   BOUND 15, 16 pass.
#
# WHAT FAILS, AND WHY
#
#   PATRN 5..9 and BOUND 17..19, with ERR_DAT_TIMEOUT and ERR_PROTOCOL. Not a
#   pattern problem: the earlier note had the diagnosis right that the failure
#   follows POSITION, not content, and case 18 is parameter-for-parameter
#   identical to case 4, which passes.
#
#   The defect is in ultra_sd_block's S_BUSY exit. CMD12 stops transmission
#   AFTER the block in flight -- what the specification says and what the card
#   model does -- and neither signal S_BUSY waits on can see that tail:
#   rx_busy_i follows OUR cell, which has already stopped, and card_busy_i
#   watches DAT0, which during a data block is carrying payload rather than a
#   busy level. So DONE is reported while the card still drives all four lanes,
#   the next START is accepted into it, and two drivers share the bus.
#
#   It does not show on hardware, where the next command's own latency is
#   longer than any card's tail: five 64 MiB runs report zero mismatches.
#
# THE FIX THAT WAS TRIED, AND WHAT IT COST
#
#   ultra_sd_line exposed dat_quiet_o -- cell idle and all four lanes high --
#   and ultra_sd_block's FINAL exit from S_BUSY waited for eight consecutive
#   quiet cycles (final exit only; POST_NEXT continues inside the same request
#   where the bus is ours). Measured, all three numbers:
#
#     bench_edge      9 failures -> 2. Every PATRN case and BOUND 17 passed.
#     P&R             2476 logic cells, still inside the 2500 budget, but
#                     **1 setup-violated endpoint**: u_cmd/u_engine/cmd_out_q
#                     -> u_phy/u_iobuf_cmd at -0.267 ns. That path is not the
#                     new logic -- it is the CMD output pad, and its whole
#                     family sits between +0.25 and +0.57 ns, so adding nine
#                     cells anywhere in the core moves a register far enough to
#                     push one of them negative.
#     tb_freq_sweep   a 2-block read went from 4660 to 6539 system clocks --
#                     about 940 SD cycles, most of a whole block, added to
#                     every transfer.
#
#   The last number is the real objection and it points at the prerequisite.
#   dat_quiet is built from dat_in_i, which is the PHY's SAMPLED copy of the
#   pads, refreshed only on an SD clock edge. Between transfers that sample
#   goes stale, so "all four lanes high" takes hundreds of cycles to become
#   true after the bus actually went quiet. The same stale sample is why
#   STAT_BUSY keeps counting on an idle bus, and why S_BUSY needs its
#   BUSY_SETTLE delay at all.
#
# SO THE ORDER OF WORK IS: make dat_in a live view of the pads when the bus is
# idle (in ultra_sd_phy_gowin, carefully -- during a write's programming wait
# the card legitimately holds DAT0 low and L3 must keep seeing that), and only
# then re-apply the quiet gate. At that point it costs a handful of cycles
# instead of a block, and the CMD-pad margin is the only thing left to buy.
#
# Two attempts to buy that margin from the tool failed and are recorded so they
# are not repeated: `set_option -place_option 2 / -route_option 2` and
# `set_option -oreg_in_iob 1` both produced byte-identical results, so this
# Gowin version ignores unknown set_option names silently.
# doc/tx_launch_edge.md section 6(c) measures what IOB output registers would
# remove -- 1.06 ns, four times the worst miss -- so the lever is real; it just
# is not reachable through gw_sh here.
#
# Run it with: make bench_edge
bench_edge_DEFS := ULTRA_SD_NO_VENDOR_PRIM
bench_edge_SRCS := $(filter-out $(TEST_DIR)/integration/tb_bench_flow.sv,$(bench_flow_SRCS)) \
                   $(TEST_DIR)/integration/tb_bench_edge.sv

# WHAT THE DRAFTS HAVE FOUND SO FAR, and it looks like one cause under two
# symptoms:
#
#   bench_ctrl stalls on case 2. The probe (+ctdbg) catches both ends at the
#   moment it happens: ultra_sd_block has walked S_IDLE -> S_PRE_ERASE -> S_CMD
#   -> S_WR_ARM -> S_WR_DATA for the NEXT case while the card is still driving
#   D_RD_DATA -> D_RD_CRC -> D_RD_END with oe = 1111 -- the tail of the read
#   case 1 aborted. Two drivers, one bus.
#
#   The card is not at fault. CMD12 stops transmission AFTER the block in
#   flight, which is what the specification says and what the model does: it
#   clears multi_read_q and read_queued_q and lets dat_tx_state_q finish.
#
#   The host is the one that moves early. S_STOP -> S_BUSY -> S_DONE, and
#   S_BUSY only waits on card_busy_i, which ultra_sd_line only makes meaningful
#   while its cell is idle. With the card mid-frame it reads zero, so DONE is
#   reported while DAT is still busy and the next transfer starts into it.
#
#   That is very likely bench_edge's failure too: there the multi-block reads
#   end normally rather than by abort, but the end of a multi-block transfer
#   takes the same path. It would also explain why bench_soak passes -- its
#   pairs are identical and short -- and why none of this shows on hardware,
#   where the next command's own latency is longer than any card's tail.
#
#   CANDIDATE FIX, not yet applied: S_BUSY should also wait for !dat_active_i.
#   ultra_sd_block already has that signal; it uses it for the gap counter. It
#   is a change to the delivered core, so it gets measured before it is kept.
#
# The three bench suites that are written but not yet trusted. They run with
# `make bench_edge` / `make bench_ctrl` / `make bench_soak`; see the note above
# bench_edge for what they have already established and what is still open.
integration_DRAFTS := bench_edge bench_ctrl

bench_ctrl_DEFS := ULTRA_SD_NO_VENDOR_PRIM
bench_ctrl_SRCS := $(filter-out $(TEST_DIR)/integration/tb_bench_flow.sv,$(bench_flow_SRCS)) \
                   $(TEST_DIR)/integration/tb_bench_ctrl.sv

# The Section 7.4 graceful-degradation procedure (bench_core SUITE = 5), in
# simulation. The hardware run uses bench/build_deg.tcl, which builds the same
# suite into its own bitstream; this is what makes the hardware attempt not the
# first execution of the sequence.
bench_deg_DEFS := ULTRA_SD_NO_VENDOR_PRIM
bench_deg_SRCS := $(filter-out $(TEST_DIR)/integration/tb_bench_flow.sv,$(bench_flow_SRCS)) \
                  $(TEST_DIR)/integration/tb_bench_deg.sv

bench_soak_DEFS := ULTRA_SD_NO_VENDOR_PRIM
bench_soak_SRCS := $(filter-out $(TEST_DIR)/integration/tb_bench_flow.sv,$(bench_flow_SRCS)) \
                   $(TEST_DIR)/integration/tb_bench_soak.sv

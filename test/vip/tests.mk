# Interface-protocol tests (VIP level): the bus interfaces checked against the
# AMBA specification itself, independent of what the core does with the data.
#
# Two lanes, deliberately:
#
#   cocotb/   The real verification IP. cocotbext-axi (MIT, Alex Forencich) is
#             the established open-source AXI VIP: AxiLiteMaster, AxiStreamSource
#             and AxiStreamSink drive the buses with randomised handshake timing
#             and check protocol compliance themselves. It runs in Python over
#             VPI, so it does not care that Icarus has no UVM and no class
#             support. This is where the coverage comes from.
#
#   *.sv      Our own monitors, under common/vip/. They exist because the other
#             categories -- functional, stress -- must be runnable without a
#             Python environment, and because a checker bound into every
#             testbench costs nothing to leave on. tb_vip_selftest.sv is what
#             earns them their trust: it commits every violation on purpose and
#             asserts that exactly the right property fires.
#
# The two lanes meet in vip/hdl/vip_axi_top.sv, where the SV monitors watch the
# same buses cocotbext-axi is driving. Agreement there is the cross-check; the
# self-test is the calibration.

vip_TESTS := vip_selftest sd_card_model

vip_selftest_SRCS := $(PKG) \
                     $(TEST_DIR)/common/vip/axi4_lite_monitor.sv \
                     $(TEST_DIR)/common/vip/axis_monitor.sv \
                     $(TEST_DIR)/vip/tb_vip_selftest.sv

sd_card_model_SRCS := $(PKG) \
                      $(RTL_DIR)/crc/ultra_sd_crc7.sv \
                      $(RTL_DIR)/crc/ultra_sd_crc16.sv \
                      $(RTL_DIR)/ultra_sd_cmd.sv \
                      $(RTL_DIR)/ultra_sd_cmd_tx.sv \
                      $(RTL_DIR)/ultra_sd_init.sv \
                      $(RTL_DIR)/ultra_sd_protocol.sv \
                      $(RTL_DIR)/ultra_sd_line.sv \
                      $(TEST_DIR)/common/models/sd_card_model.sv \
                      $(TEST_DIR)/vip/tb_sd_card_model.sv

# ---- the cocotb lane --------------------------------------------------------
# A virtual environment rather than the system Python: cocotbext-axi pins a
# cocotb version, and the verification flow has no business dictating what is
# installed system-wide. Create it with:
#
#   python3 -m venv test/.venv && test/.venv/bin/pip install cocotbext-axi
#
VIP_VENV := $(TEST_DIR)/.venv
VIP_PY   := $(VIP_VENV)/bin/python

.PHONY: vip-cocotb vip-venv

vip-cocotb:
	@if [ ! -x $(VIP_PY) ]; then \
	  echo "The cocotb VIP needs test/.venv -- run 'make vip-venv' first."; \
	  exit 1; \
	fi
	$(VIP_PY) $(TEST_DIR)/vip/cocotb/run_vip.py

vip-venv:
	python3 -m venv $(VIP_VENV)
	$(VIP_VENV)/bin/pip install --quiet --upgrade pip
	$(VIP_VENV)/bin/pip install cocotbext-axi

# The category runs both lanes, self-test first: there is no point reading a
# monitor's verdict before knowing that the monitor works.
vip: vip-cocotb
vip-cocotb: vip_selftest

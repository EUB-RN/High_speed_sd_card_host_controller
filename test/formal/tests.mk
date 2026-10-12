# Property / assertion-based verification. Proofs over *all* inputs, not just
# the ones a random testbench happened to drive -- which is what separates this
# category from test/vip/.
#
# SymbiYosys drives the proofs. It is not part of the simulation flow, so the
# category is skipped with a message rather than failing when sby is absent.
# See README.md in this directory for what is proved and what is still open.

formal_TESTS :=

FORMAL_SBY ?= $(shell command -v sby 2>/dev/null || command -v yowasp-sby 2>/dev/null)
# z3 comes from the same venv as the cocotb VIP; yosys-smtbmc looks for its
# solver on PATH.
FORMAL_PATH := $(TEST_DIR)/.venv/bin:$(PATH)

# Only proofs that CLOSE go in here. The FIFO property set is written and runs
# but does not close yet -- see README.md -- and a red default target teaches
# people to ignore it.
FORMAL_SBYS := $(TEST_DIR)/formal/axi4_lite_slave.sby

# Opt-in: the commit/rewind FIFO property set, as far as it has got.
#   make formal-fifo
FORMAL_SBYS_WIP := $(TEST_DIR)/formal/async_fifo.sby

.PHONY: formal-proofs

formal-proofs:
	@if [ -z "$(FORMAL_SBY)" ]; then \
	  echo "formal: SymbiYosys not found (sby / yowasp-sby) -- skipping."; \
	  echo "        See test/formal/README.md for how to install it."; \
	else \
	  for f in $(FORMAL_SBYS); do \
	    echo "$(FORMAL_SBY) -f $$f"; \
	    ( cd $$(dirname $$f) && PATH="$(FORMAL_PATH)" $(FORMAL_SBY) -f $$(basename $$f) ) || exit 1; \
	  done; \
	fi

formal: formal-proofs

.PHONY: formal-fifo

formal-fifo:
	@if [ -z "$(FORMAL_SBY)" ]; then \
	  echo "formal: SymbiYosys not found (sby / yowasp-sby) -- skipping."; \
	else \
	  for f in $(FORMAL_SBYS_WIP); do \
	    echo "$(FORMAL_SBY) -f $$f"; \
	    ( cd $$(dirname $$f) && PATH="$(FORMAL_PATH)" $(FORMAL_SBY) -f $$(basename $$f) ) || exit 1; \
	  done; \
	fi

# Still to write here:
#   faxis_slave bind     AXI4-Stream properties on axis_rd_master/axis_wr_slave
#   bind_clk_controller  gating and duty-cycle properties
#   cdc_assertions       one property per crossing listed in doc/cdc.md

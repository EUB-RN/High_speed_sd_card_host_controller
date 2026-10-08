# -----------------------------------------------------------------------------
# Shared simulator plumbing for every test category.
#
# A category contributes tests by appending to <category>_TESTS and declaring
# one <test>_SRCS list per test, plus an optional <test>_DEFS list of macros to
# define; nothing else. The rule engine lives here so that adding a category
# never means duplicating simulator flags.
#
# SIM selects the simulator:
#   SIM=iverilog  (default) Icarus Verilog
#   SIM=verilator           Verilator 5.x, via --binary --timing
# Verilator 4.x cannot run a timed SystemVerilog testbench; it is still the
# right tool for `make lint`.
# -----------------------------------------------------------------------------

SIM       ?= iverilog
VERILATOR ?= verilator
IVERILOG  ?= iverilog

PKG := $(RTL_DIR)/ultra_sd_pkg.sv

# Every testbench gets the common/ directory on its include path, so shared
# checker macros and models are reachable as `include "...".
INCDIRS := $(TEST_DIR)/common

PLUSARGS := $(if $(DUMP),+dump,)
SEED     ?=
PLUSARGS += $(if $(SEED),+seed=$(SEED),)

ifeq ($(SIM),iverilog)

# $(1) test name, $(2) category
define TEST_rule
.PHONY: $(1)
$(1): $$($(1)_SRCS)
	@mkdir -p $$(BUILD)/$(2)
	$$(IVERILOG) -g2012 -Wall -Wno-timescale $$(addprefix -I,$$(INCDIRS)) \
	  $$(addprefix -D,$$($(1)_DEFS)) \
	  -o $$(BUILD)/$(2)/$(1).vvp -s tb_$(1) $$($(1)_SRCS)
	@vvp $$(BUILD)/$(2)/$(1).vvp $$(PLUSARGS)
endef

else ifeq ($(SIM),verilator)

define TEST_rule
.PHONY: $(1)
$(1): $$($(1)_SRCS)
	@mkdir -p $$(BUILD)/$(2)/$(1)
	$$(VERILATOR) --binary --timing -Wall -Wno-fatal \
	  $$(addprefix +incdir+,$$(INCDIRS)) \
	  $$(addprefix +define+,$$($(1)_DEFS)) \
	  --top-module tb_$(1) -o $(1) --Mdir $$(BUILD)/$(2)/$(1) $$($(1)_SRCS)
	@$$(BUILD)/$(2)/$(1)/$(1) $$(PLUSARGS)
endef

else
$(error SIM must be iverilog or verilator, got "$(SIM)")
endif

# -----------------------------------------------------------------------------
# Verification entry point. Tests are grouped by verification category; each
# category owns a directory and a tests.mk that declares what it contains.
#
#   make                      the regression: every category that has tests
#   make unit                 one category
#   make clk_controller       one test, wherever it lives
#   make list                 what exists, by category
#   make ... DUMP=1           also write a .vcd
#   make ... SIM=verilator    run under Verilator 5.x instead of Icarus
#   make lint                 the R-LANG-9 zero-warning lint gate
#   make clean
#
# Every testbench is self-checking: it prints PASSED or FAILED and exits
# non-zero on failure, so these targets work directly as a CI gate (R-DEL-7).
# -----------------------------------------------------------------------------

TEST_DIR  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(TEST_DIR)/..)
RTL_DIR   := $(REPO_ROOT)/rtl
BENCH_DIR := $(REPO_ROOT)/bench/rtl
BUILD     := $(TEST_DIR)/build

# Order is the order the regression runs in: cheap and narrow first, so a
# broken divisor fails in seconds rather than after the soak.
CATEGORIES := unit functional integration vip error_injection formal coverage stress performance

include $(TEST_DIR)/mk/common.mk
include $(patsubst %,$(TEST_DIR)/%/tests.mk,$(CATEGORIES))

ALL_TESTS := $(foreach c,$(CATEGORIES),$($(c)_TESTS))

.PHONY: all test regression list lint clean $(CATEGORIES)

# Kategori tests.mk'leri include edilirken kendi hedeflerini tanimlar; include
# edilen ilk hedef make'in dogal default goal'u olur ve `make` regresyon yerine
# o tek hedefi kosar. Default goal'u burada acikca sabitliyoruz.
.DEFAULT_GOAL := all

all: regression
test: regression
regression: $(CATEGORIES)

# One rule per test, told which category it belongs to so build output stays
# grouped the same way the sources are.
$(foreach c,$(CATEGORIES),$(foreach t,$($(c)_TESTS),$(eval $(call TEST_rule,$(t),$(c)))))

# DRAFTS get a rule but no place in the regression. A suite whose failures have
# not been root-caused belongs behind an explicit `make <name>`, where whoever
# runs it is expecting them -- not in a gate everyone else has to walk past. The
# list below is the honest answer to "what exists but is not trusted yet", and a
# draft graduates by moving one word from _DRAFTS to _TESTS.
$(foreach c,$(CATEGORIES),$(foreach t,$($(c)_DRAFTS),$(eval $(call TEST_rule,$(t),$(c)))))

# A category target depends on its tests; an empty category is not an error,
# it is a category whose tests are not written yet.
$(foreach c,$(CATEGORIES),$(eval $(c): $$($(c)_TESTS)))

list:
	@printf 'SIM=%s\n\n' '$(SIM)'
	@$(foreach c,$(CATEGORIES), \
	  printf '%-16s %s\n' '$(c)' '$(if $($(c)_TESTS),$($(c)_TESTS),(none yet))';)
	@printf '\n%-16s %s\n' 'drafts' \
	  '$(if $(strip $(foreach c,$(CATEGORIES),$($(c)_DRAFTS))),$(foreach c,$(CATEGORIES),$($(c)_DRAFTS)),(none))'
	@printf '%-16s %s\n' '' 'run with: make <name>  -- not in the regression'

# R-LANG-9: zero warnings over the synthesizable hierarchy. Lint is a category
# of its own in spirit, but it needs no testbench, so it stays a plain target.
include $(TEST_DIR)/mk/lint.mk

clean:
	rm -rf $(BUILD) $(TEST_DIR)/*.vcd $(TEST_DIR)/*/*.vcd

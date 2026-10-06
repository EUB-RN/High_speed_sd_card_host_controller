# -----------------------------------------------------------------------------
# R-LANG-9 lint gate. One entry per synthesizable top: the module name, then
# the files it needs. Verilator 4.x is fine here even though it cannot run the
# timed testbenches.
# -----------------------------------------------------------------------------

LINT_TOPS := clk_controller

clk_controller_LINT_SRCS := $(PKG) $(RTL_DIR)/clk_controller.sv

.PHONY: lint $(addprefix lint-,$(LINT_TOPS))

lint: $(addprefix lint-,$(LINT_TOPS))

define LINT_rule
lint-$(1): $$($(1)_LINT_SRCS)
	$$(VERILATOR) --lint-only -Wall $$($(1)_LINT_SRCS) --top-module $(1)
endef

$(foreach t,$(LINT_TOPS),$(eval $(call LINT_rule,$(t))))

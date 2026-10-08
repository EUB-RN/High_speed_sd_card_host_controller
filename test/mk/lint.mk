# -----------------------------------------------------------------------------
# R-LANG-9 lint gate. One entry per synthesizable top: the module name, then
# the files it needs. Verilator 4.x is fine here even though it cannot run the
# timed testbenches.
# -----------------------------------------------------------------------------

LINT_TOPS := clk_controller system_controller ultra_sd_phy_gowin \
              ultra_sd_block ultra_sd_top

clk_controller_LINT_SRCS := $(PKG) $(RTL_DIR)/clk_controller.sv

system_controller_LINT_SRCS := $(PKG) $(RTL_DIR)/system_controller.sv

# Satici makrolari (IOBUF / DQCE / DCS) Verilator'de tanimli degil: lint
# davranissal modelleri uzerinden kosar.
# clk_controller artik PHY'nin icinde: bolucu de bu lint kapsaminda.
ultra_sd_phy_gowin_LINT_SRCS := $(PKG) $(RTL_DIR)/clk_controller.sv \
                                $(RTL_DIR)/ultra_sd_phy_gowin.sv
ultra_sd_phy_gowin_LINT_DEFS := ULTRA_SD_NO_VENDOR_PRIM



ultra_sd_block_LINT_SRCS := $(PKG) $(RTL_DIR)/ultra_sd_block.sv

# Butun hiyerarsi. Tek bir modulu degil, birbirine BAGLI halini sinar: port
# uyusmazligi, bagli kalmis giris ve kullanilmayan sinyal buradan cikar.
ultra_sd_top_LINT_SRCS := $(PKG) \
                          $(RTL_DIR)/axi4/async_fifo.sv \
                          $(RTL_DIR)/axi4/axi4_lite_slave.sv \
                          $(RTL_DIR)/axi4/axis_rd_master.sv \
                          $(RTL_DIR)/axi4/axis_wr_slave.sv \
                          $(RTL_DIR)/ultra_sd_reg.sv \
                          $(RTL_DIR)/axi4/ultra_sd_axi_top.sv \
                          $(RTL_DIR)/ultra_sd_block.sv \
                          $(RTL_DIR)/crc/ultra_sd_crc7.sv \
                          $(RTL_DIR)/crc/ultra_sd_crc16.sv \
                          $(RTL_DIR)/ultra_sd_cmd.sv \
                          $(RTL_DIR)/ultra_sd_line.sv \
                          $(RTL_DIR)/clk_controller.sv \
                          $(RTL_DIR)/system_controller.sv \
                          $(RTL_DIR)/ultra_sd_phy_gowin.sv \
                          $(RTL_DIR)/ultra_sd_top.sv
ultra_sd_top_LINT_DEFS := ULTRA_SD_NO_VENDOR_PRIM

.PHONY: lint $(addprefix lint-,$(LINT_TOPS))

lint: $(addprefix lint-,$(LINT_TOPS))

define LINT_rule
lint-$(1): $$($(1)_LINT_SRCS)
	$$(VERILATOR) --lint-only -Wall $$(addprefix +define+,$$($(1)_LINT_DEFS)) \
	  $$($(1)_LINT_SRCS) --top-module $(1)
endef

$(foreach t,$(LINT_TOPS),$(eval $(call LINT_rule,$(t))))

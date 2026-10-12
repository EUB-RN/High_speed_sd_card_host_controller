# -----------------------------------------------------------------------------
# Headless Gowin build. Kaynaklar DOGRUDAN ../rtl'den okunur: IDE'nin proje
# dizinine kopya almasi gibi bir sey yok, dolayisiyla repo'da bir dosyayi
# degistirdigin anda bir sonraki build onu gorur.
#
#   cd syn
#   QT_QPA_PLATFORM=offscreen LD_LIBRARY_PATH=$HOME/Downloads/IDE/lib \
#     ~/Downloads/IDE/bin/gw_sh build.tcl
#
# Cikti:  impl/gwsynthesis/  sentez raporu (kaynak kullanimi, netlist)
#         impl/pnr/          P&R, zamanlama ve bitstream -- asagiya bak
#
# ULTRA_SD_NO_VENDOR_PRIM BURADA TANIMLI DEGIL: sentezde gercek Gowin IOBUF /
# DQCE / DCS primitifleri ornekleniyor. O makro yalnizca iverilog/verilator
# simulasyonu icindir (ultra_sd_phy_gowin.sv basligi).
# -----------------------------------------------------------------------------

set_device -name GW2A-18C GW2A-LV18PG256C8/I7

# ---- L4: AXI, register dosyasi, akis adaptorleri ----------------------------
add_file ../rtl/ultra_sd_pkg.sv
add_file ../rtl/axi4/async_fifo.sv
add_file ../rtl/axi4/axi4_lite_slave.sv
add_file ../rtl/axi4/axis_rd_master.sv
add_file ../rtl/axi4/axis_wr_slave.sv
add_file ../rtl/ultra_sd_reg.sv
add_file ../rtl/axi4/ultra_sd_axi_top.sv

# ---- L3 ve durum / sayac sahibi ---------------------------------------------
add_file ../rtl/ultra_sd_block.sv

# ---- L2: komut motoru + baslatma merdiveni (tek modul, arbiter yok) --------
add_file ../rtl/ultra_sd_cmd.sv
add_file ../rtl/ultra_sd_cmd_tx.sv
add_file ../rtl/ultra_sd_init.sv
add_file ../rtl/ultra_sd_protocol.sv

# ---- L1: DAT cerceveleme ve CRC --------------------------------------------
add_file ../rtl/crc/ultra_sd_crc7.sv
add_file ../rtl/crc/ultra_sd_crc16.sv
add_file ../rtl/ultra_sd_line.sv

# ---- L0 ve sistem -----------------------------------------------------------
add_file ../rtl/clk_controller.sv
add_file ../rtl/rst_sync.sv
add_file ../rtl/system_controller.sv
add_file ../rtl/ultra_sd_phy_gowin.sv
add_file ../rtl/ultra_sd_top.sv

# ---- zamanlama kisitlari (R-CLK-6) -----------------------------------------
add_file ../constr/ultra_sd.sdc

set_option -top_module ultra_sd_top
set_option -verilog_std sysv2017

# sd_dat[0] M8 pininde ve o pin SSPI SO/D1 konfigurasyon pini; serbest
# birakilmazsa yerlestirici reddeder (pin_check/README.md adim 5).
set_option -use_sspi_as_gpio 1

# SENTEZ. P&R'a gecilmiyor, cunku ultra_sd_top'un AXI portlari pede cikmaz:
# Figure 4-1'e gore cekirdegi ornekleyen taraf harness'tir (R-DEL-5), ped
# atamasi da onun .cst'sinde olur. Kaynak kullanimi ve sentez uyarilari icin
# bu yeterli; reports/gowin_timing.txt ve gowin_resource.txt harness'li
# projeden alinir.
run syn

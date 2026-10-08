# Sanity bitstream: clock + PLL + UART only, no SD logic. See sanity_top.sv.
#   cd bench/sanity
#   QT_QPA_PLATFORM=offscreen LD_LIBRARY_PATH=$HOME/Downloads/IDE/lib ~/Downloads/IDE/bin/gw_sh build.tcl
set_device -name GW2A-18C GW2A-LV18PG256C8/I7
add_file ../rtl/bench_uart_tx.sv
add_file sanity_top.sv
add_file sanity.cst
set_option -top_module sanity_top
set_option -verilog_std sysv2017
run all

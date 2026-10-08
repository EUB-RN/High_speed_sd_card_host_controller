set_device -name GW2A-18C GW2A-LV18PG256C8/I7
add_file ../rtl/ultra_sd_pkg.sv
add_file ../rtl/ultra_sd_block.sv
set_option -top_module ultra_sd_block
set_option -verilog_std sysv2017
run syn

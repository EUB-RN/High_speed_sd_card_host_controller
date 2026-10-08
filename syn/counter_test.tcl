
set_device -name GW2A-18C GW2A-LV18PG256C8/I7
add_file counter_test.sv
set_option -top_module counter_test
set_option -verilog_std sysv2017
run syn

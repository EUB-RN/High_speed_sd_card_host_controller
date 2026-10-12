# CMD TX register separation

Measured with GowinSynthesis for GW2A-LV18PG256C8/I7, top `ultra_sd_cmd`,
SystemVerilog 2017, default parameters, debug disabled, identical options.
Only TX CRC storage differs: the remaining six CRC bits have their own shifter
instead of using the low six bits of the command shifter. RX is unchanged.

| Resource | Before | After | Difference |
|---|---:|---:|---:|
| LUT | 365 | 363 | -2 (-0.55%) |
| Register | 209 | 214 | +5 |
| Peak RSS (KiB) | 76552 | 76460 | |

These are standalone module synthesis results, not whole-design utilization
or placed-and-routed timing. Integration can change optimization and packing.
The RTL adds six CRC storage bits; net synthesis register count rises by five.

The GUI Tcl launcher failed at the parser stage under this environment;
calling GowinSynthesis directly with its generated project file succeeded.
Both runs were sequential with 512 MiB virtual-memory and 40-second wall limits.

Validation: command unit test (10 checks), basic initialization (44 checks),
full initialization (360 checks), and Verilator protocol lint with debug enabled
passed. No full-system benchmark or place-and-route run was performed.

Source SHA-256 (ultra_sd_cmd.sv):
- before: `3a3c6b5d2437c0ca12a93fc9ad65e5fb53d7a6b5aadc84853b30d9e188dd7374`
- after: `71ff45ef73da30746c3dc7f08d93c80aad51d0a572b69e6d91ed661ffce12e4b`

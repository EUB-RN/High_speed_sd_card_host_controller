# Shared verification infrastructure

Nothing here is a test. Anything used by more than one testbench belongs in
this directory, so that the categories stay thin.

| Path | What goes here |
|---|---|
| `common/` | checker macros (`CHECK`, `CHECK_EQ`), the bounded-wait watchdog, clock/reset drivers, the pass/fail epilogue every testbench ends with |
| `common/models/` | the behavioural SD card model -- the one piece of infrastructure worth the most, since the R-DEL-7 fault injection runs against it |
| `common/vip/` | our own AXI4-Lite and AXI4-Stream protocol monitors and random masters/slaves |
| `common/cov/` | covergroups, instantiated by the functional and vip testbenches |

The pass/fail contract, which `test/unit/tb_clk_controller.sv` already
follows and which the Makefile depends on: print `PASSED` or `FAILED` with a
check count, exit non-zero on failure, and bound every wait with a watchdog so
a broken design fails instead of hanging.

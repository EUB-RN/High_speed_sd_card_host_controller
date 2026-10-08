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

## SD card model

`models/sd_card_model.sv` is a pin-level SDHC card VIP that runs in the plain
SystemVerilog/Icarus flow.  It implements the command subset in
`ultra_sd_pkg`, 1-bit and 4-bit DAT transfers, per-lane CRC16, write status
tokens, programming busy, and a byte-addressable backing store.  Tests can
preload or inspect that store with the public hierarchical helpers:

```systemverilog
u_card.write_byte(byte_address, value);
value = u_card.read_byte(byte_address);
```

The five `inject_*` inputs provide command timeout, command CRC, read-data CRC,
write-token CRC rejection, and stuck-busy faults.  Assert a fault while the
applicable transaction is issued, then release it after the expected recovery
or terminal error.  `protocol_error_o` is the inverse-direction checker: it
latches if the host sends a malformed command frame.

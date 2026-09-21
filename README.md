# ultra_sd

SD card host controller -- RTL & PHY. SystemVerilog, targeting the Gowin
GW2A-18C on a Sipeed Tang Primer 20K + Dock, SD Physical Layer v6.00, High
Speed 4-bit at 50 MHz, 3.3 V. AXI4-Lite for control, AXI4-Stream for payload.
Raw block device -- no filesystem.

Built against *ultra_sd -- Design Requirements & Acceptance Specification*
v1.0. Requirement IDs (`R-ARCH-1`, `R-IF-6`, …) in this repository refer to
that document.

## Repository layout (Section 13.1)

```
ultra_sd/
  rtl/
    ultra_sd_pkg.sv        shared types, opcodes, localparams
    ultra_sd_top.sv        wiring only
    ultra_sd_reg.sv        Table 5-1 register file (0-cycle rd, 1-cycle wr)
    axi4/
      axi4_lite_slave.sv   AXI4-Lite handshake -> simple read/write bus
      ultra_sd_axi_top.sv  L4: regfile + AXI4-Stream adapters, interrupt
    ultra_sd_block.sv      LBA sequencing, streaming, FIFOs
    ultra_sd_cmd.sv        command issue, response parsing
    ultra_sd_init.sv       initialisation FSM
    ultra_sd_line.sv       CMD/DAT serialisation and framing
    ultra_sd_crc.sv        CRC7 and one CRC16 lane
    ultra_sd_phy_gowin.sv  the ONLY file with vendor primitives
  tb/
    ...                    testbench, card model if written
  constr/
    ultra_sd.sdc           timing constraints (the .cst is supplied)
  doc/
    README.md              build, integrate, register map, block diagram
    cdc.md                 every clock-domain crossing, if any
    report.md              measurements, per Section 13.3
    checklist.md           submission checklist, Appendix C
  reports/
    gowin_resource.txt     post-P&R utilisation
    gowin_timing.txt       timing report at 50 MHz
    verilator_lint.txt     zero-warning lint output
    uart_run1..5.log       the five measurement runs
    uart_soak.log          30-minute soak
    uart_degradation.log   Section 7.4 procedure
```

The RTL file names are suggestions; the five-layer hierarchy of Figure 4-1 is
not (R-ARCH-1). The directory layout above is required.

## Status

Skeleton, plus the register file. Module headers, the normative port list of
Figure 5-1 and the error codes of Table 5-3 are in place, and
`rtl/ultra_sd_reg.sv` implements the full Table 5-1 map behind the simple
`wr_en` / `rd_en` bus that `axi4/axi4_lite_slave.sv` presents. The protocol
layers below it are still stubs.

## Documentation

- [doc/README.md](doc/README.md) -- integration guide (R-DEL-1)
- [doc/cdc.md](doc/cdc.md) -- clock-domain crossings (R-DEL-2)
- [doc/report.md](doc/report.md) -- measurement report (R-DEL-4)
- [doc/checklist.md](doc/checklist.md) -- submission checklist (Appendix C)

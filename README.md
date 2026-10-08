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
      async_fifo.sv        dual-clock FIFO, gray pointers (axi_clk <-> sd_clk)
      axis_rd_master.sv    AXI4-Stream master, read payload card -> host
      axis_wr_slave.sv     AXI4-Stream slave, write payload host -> card
    ultra_sd_block.sv      LBA sequencing, streaming, retry and recovery
    ultra_sd_stat.sv       Table 5-1 status view, Table 5-2 counters
    ultra_sd_cmd.sv        command issue, response parsing
    ultra_sd_cmd_arb.sv    shares the command port: init ladder vs data layer
    ultra_sd_init.sv       initialisation FSM
    ultra_sd_line.sv       CMD/DAT serialisation and framing
    ultra_sd_crc.sv        CRC7 and one CRC16 lane
    ultra_sd_phy_gowin.sv  the ONLY file with vendor primitives
  test/                    verification, one directory per category
    Makefile               `make` is the regression; see test/README.md
    common/                card model, AXI VIP, covergroups, checker macros
    unit/                  one module against its own contract
    functional/            end-to-end scenarios against the card model
    vip/                   bus interfaces against the AMBA specification
    error_injection/       hostile card, plus the R-DEL-7 RTL mutation runs
    formal/                SVA properties and proofs
    coverage/              functional coverage closure
    stress/                long, randomised, soak
    performance/           throughput and the characterisation sweep
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

All five layers are wired together in `rtl/ultra_sd_top.sv` and the whole
hierarchy synthesises for the GW2A-18C. Simulation: `cd test && make` is green
(unit, functional, AXI VIP), and `make lint` is zero-warning on every
synthesizable top including the full hierarchy.

| Layer | State |
|---|---|
| L4 `axi4/` | AXI4-Lite + Table 5-1 register file + both stream adapters. The payload FIFOs support block-granular commit / rewind, which is what makes a CRC16 retry possible without a block buffer. |
| L3 `ultra_sd_block.sv` | LBA sequencing, one CMD18 / CMD25 per request, ACMD23 pre-erase, per-block CRC retry, CMD12 + CMD13 local recovery, backpressure by stopping and resuming the stream. |
| — `ultra_sd_stat.sv` | Table 5-1 read-only view and all Table 5-2 counters, in the SD clock domain, saturating, cleared by `CTRL.STAT_CLEAR`. |
| L2 `ultra_sd_cmd.sv`, `ultra_sd_cmd_arb.sv`, `ultra_sd_init.sv` | Command issue and response decode, port arbitration between the init ladder and the data layer, the Table 6-1 ladder. |
| L1 `ultra_sd_line.sv`, `crc/` | DAT framing, CRC7, CRC16 per lane. |
| L0 `ultra_sd_phy_gowin.sv` | Pads, tristate, sampling phase, DQCE gating and DCS pad mux. The only file with vendor primitives. |

Open: `ultra_sd_init` cannot yet read a data block over DAT (ACMD51 SCR and the
CMD6 switch status), because L1's frame length is a parameter rather than a port
and its single `start_i` is now driven by L3. Until that is resolved the High
Speed switch is not verified (R-FUNC-3) and the ladder stays at Default Speed.

Synthesis, `syn/build.tcl` (sources read straight from `rtl/`, no project file):

| | |
|---|---|
| Logic | 2345 / 20736 — 2246 LUT, 81 ALU, 3 RAM16 |
| Registers | 1261, no latches |
| BSRAM | 2 / 46 |
| rPLL | 0 (R-CLK-5) |
| Fmax (post-synthesis) | `clk` 135 MHz, `cmd_clk` 115 MHz, `line_clk` 109 MHz against a 100 MHz constraint |

Those are pre-place-and-route numbers for the core alone; the post-P&R figures
of `reports/` need the harness that instantiates it.

## Build

```bash
cd syn
QT_QPA_PLATFORM=offscreen LD_LIBRARY_PATH=$HOME/Downloads/IDE/lib \
  ~/Downloads/IDE/bin/gw_sh build.tcl
```

`syn/build.tcl` is the authoritative file list and reads every source straight
out of `rtl/` with a relative path, so editing a file in the repo is enough --
there is no project directory holding a copy that can go stale. The same script
sets the device, the SystemVerilog dialect and `use_sspi_as_gpio` (`sd_dat[0]`
is on the SSPI pin), so a build is reproducible without clicking through the
IDE. Output lands in `syn/impl/`, which is gitignored.

If you would rather drive the IDE: add the files **by reference** and keep the
paths pointing into `rtl/`. Whether that happened is visible in the `.gprj` --
each `<File path="...">` entry should read `../../rtl/...` and not a copy inside
the project folder. A copied file is a separate file and will not follow the
repo.

`ULTRA_SD_NO_VENDOR_PRIM` is deliberately **not** defined for synthesis: that
macro swaps the Gowin `IOBUF` / `DQCE` / `DCS` primitives for behavioural models
and exists only for `iverilog` and `verilator`.

## Documentation

- [doc/README.md](doc/README.md) -- integration guide (R-DEL-1)
- [doc/cdc.md](doc/cdc.md) -- clock-domain crossings (R-DEL-2)
- [doc/report.md](doc/report.md) -- measurement report (R-DEL-4)
- [doc/checklist.md](doc/checklist.md) -- submission checklist (Appendix C)

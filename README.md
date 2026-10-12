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
    ultra_sd_block.sv      L3: LBA sequencing, streaming, retry and recovery
    ultra_sd_protocol.sv   L2: init/block request selection and response routing
    ultra_sd_cmd.sv        L2: command framing, response reception, CRC, retries
    ultra_sd_init.sv       L2: initialisation ladder and capability negotiation
    ultra_sd_line.sv       L1: CMD/DAT serialisation and framing
    crc/ultra_sd_crc7.sv   CRC7 over the command frame
    crc/ultra_sd_crc16.sv  CRC16, one lane
    clk_controller.sv      SD clock divider, instantiated inside the PHY
    system_controller.sv   reset, card detect, phase FSM, Table 5-1 view
    rst_sync.sv            async assert / sync deassert reset synchroniser
    ultra_sd_phy_gowin.sv  the ONLY file with vendor primitives
  test/                    verification, one directory per category
    Makefile               `make` is the regression; see test/README.md
    common/                card model, AXI VIP, covergroups, checker macros
    unit/                  one module against its own contract
    functional/            end-to-end scenarios against the card model
    integration/           adjacent layers together, and the bench suites
    vip/                   bus interfaces against the AMBA specification
    error_injection/       hostile card, plus mutation.sh (R-DEL-7)
    formal/                SVA properties and SymbiYosys proofs
    coverage/              functional coverage closure
    stress/                long, randomised, soak
    performance/           throughput, counter cross-check, divisor sweep
  bench/                   the on-board measurement harness (no soft CPU)
    build.tcl              tier bitstream      -> impl/pnr/project.fs
    build_soak.tcl         R-MEAS-5 soak       -> impl/pnr/soak.fs
    build_deg.tcl          R-DEG-7 degradation -> impl/pnr/deg.fs
    tools/uart_read        libftdi reader, FT2232H channel B, 115200 8N1
  constr/
    ultra_sd.sdc           timing constraints, sign-off
    ultra_sd_margin20.sdc  the same design with 20% more clock
  syn/
    build.tcl              synthesis only
    core_pnr/build.tcl     full P&R of the core alone; SDC_FILE picks the set
    pnr_timing.py          fails on any violated endpoint -- gw_sh does not
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
| — counters | There is no separate statistics module. Each Table 5-2 counter lives inside the FSM that generates its event, in that FSM's clock domain (R-IF-11), saturating, cleared by `CTRL.STAT_CLEAR`: `STAT_DATA`/`STAT_BUSY` in `ultra_sd_line`, `STAT_GAP` and the CRC half of `STAT_RETRY` in `ultra_sd_block`, the command half in `ultra_sd_cmd`. |
| L2 `ultra_sd_cmd.sv`, `ultra_sd_protocol.sv`, `ultra_sd_init.sv` | Command issue and response decode, port arbitration between the init ladder and the data layer, the Table 6-1 ladder. |
| L1 `ultra_sd_line.sv`, `crc/` | DAT framing, CRC7, CRC16 per lane. |
| L0 `ultra_sd_phy_gowin.sv` | Pads, tristate, sampling phase, DQCE gating and DCS pad mux. The only file with vendor primitives. |

The initialisation ladder reads data blocks over DAT (ACMD51 SCR and the CMD6
switch status), so the High Speed switch is negotiated and verified rather than
assumed, and the ladder reaches High Speed on a card that offers it. L1's frame
length is a port and its `start_i` is shared between L3 and the init module,
arbitrated in `ultra_sd_protocol`.

Place and route of the core alone, `syn/core_pnr/build.tcl` (device pins from
`syn/core_pnr/core_pnr_pins.cst`, timing from the constraint file named by
`SDC_FILE`):

| | |
|---|---|
| Logic | 2467 / 20736 — 2367 LUT, 100 ALU, 0 ROM16 |
| Registers | 1328 / 16173, no latches |
| BSRAM | 2 / 46 |
| rPLL | 0 (R-CLK-5) |
| Timing, sign-off constraints | 0 setup / 0 hold violated endpoints |
| Timing, +20% margin constraints | 0 setup / 0 hold violated endpoints |

The +20% set is `constr/ultra_sd_margin20.sdc`: the same design re-closed with
`clk` at 8.417 ns instead of 10.101 ns. Both runs and the reasoning behind what
the margin does and does not scale are in [doc/report.md](doc/report.md).

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

Command transport and initialization are separate RTL modules. `ultra_sd_init`
owns the startup sequence and card configuration; `ultra_sd_cmd` latches each
accepted request and handles serialization, response reception, CRC and command
retries. `ultra_sd_protocol` only selects init/block requests and routes responses.
The response-frame event arms initialization DAT reads before the command gap
finishes, and the init module captures data during that gap as well.

The CMD receiver shares a 40-bit capture register between short responses and
the used R2 fields (CSD_STRUCTURE and C_SIZE), plus one R2 end-bit flop. CRC7
still covers the full response. The 136-bit response port is combinational:
uncaptured R2 fields are zero, not a stored full CID/CSD image.

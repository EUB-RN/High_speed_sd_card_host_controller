# ultra_sd -- integration guide

Required by R-DEL-1 and R-DEL-3: enough for someone who did not write the core
to build it, program it, instantiate it and drive it, without contacting the
author.

Measurements live in [report.md](report.md); every clock-domain crossing is
enumerated in [cdc.md](cdc.md); the submission checklist is
[checklist.md](checklist.md).

---

## 1. Build and program

### The core on its own

`syn/build.tcl` synthesises `ultra_sd_top` and `syn/core_pnr/build.tcl` takes
it through place and route. Both read every source straight out of `rtl/` by
relative path, so there is no project copy that can go stale.

```bash
cd syn/core_pnr
SDC_FILE=../../constr/ultra_sd.sdc \
QT_QPA_PLATFORM=offscreen LD_LIBRARY_PATH=$HOME/Downloads/IDE/lib \
  $HOME/Downloads/IDE/bin/gw_sh build.tcl
```

`SDC_FILE` names the timing constraints: `constr/ultra_sd.sdc` is the sign-off
set, `constr/ultra_sd_margin20.sdc` the same design re-closed with 20% more
clock than the specification asks for. Reports land in `impl/pnr/`.

`gw_sh` has no `-define`. GowinSynthesis compiles the added files as one unit,
so a `` `define `` in the **first** file added reaches every file after it:
that is how the benchmark builds select a suite, and it is why the file order
in these scripts matters.

`ULTRA_SD_NO_VENDOR_PRIM` is deliberately **not** defined for synthesis. It
swaps the Gowin `IOBUF` and `DQCE` primitives for behavioural models and
exists only for `iverilog` and `verilator`.

The core alone needs pins for all 178 of its ports before P&R will place the
IOBUFs; `syn/core_pnr/core_pnr_pins.cst` supplies them, and gives every port
`IO_TYPE=LVCMOS33` so all banks share one VCCIO. It is a P&R scaffold, not a
board file -- in a real design the harness owns the pins and only the eight SD
pads of `constr/ultra_sd.cst` are fixed:

| Port | Pin |
|---|---|
| `sd_clk` | N10 |
| `sd_cmd` | R14 |
| `sd_dat[0]` | M8 |
| `sd_dat[1]` | M7 |
| `sd_dat[2]` | M10 |
| `sd_dat[3]` | N11 |
| `sd_cd` | D15 |

`sd_dat[0]` sits on the SSPI pin, so every build script sets
`use_sspi_as_gpio`. Without it the pad stays a configuration pin and the card
answers nothing.

### The benchmark, on the board

`bench/` wraps the core in a self-contained measurement harness -- an AXI4-Lite
master, a pattern generator and checker, and a UART reporter -- so the board
needs no soft CPU and no host driver.

```bash
cd bench
QT_QPA_PLATFORM=offscreen LD_LIBRARY_PATH=$HOME/Downloads/IDE/lib \
  $HOME/Downloads/IDE/bin/gw_sh build.tcl          # impl/pnr/project.fs
openFPGALoader -b tangprimer20k impl/pnr/project.fs
tools/uart_read 300000 > ../reports/run.txt        # FT2232H channel B, 115200 8N1
```

`build_soak.tcl` is the same build with `rtl/bench_defines_soak.sv` in place of
`rtl/bench_defines.sv`, producing `impl/pnr/soak.fs` for the R-MEAS-5 soak. It
exists as a second script rather than a flag because `gw_sh` takes no
arguments, so "which defines file" is the only knob a second build can turn.

**Check the timing report before trusting a run.** `gw_sh` exits 0 whether or
not the design closed, so a bitstream with setup violations programs perfectly
and then misbehaves in ways that look like design bugs:

```bash
syn/pnr_timing.py bench/impl/pnr/project_tr_content.html
```

It prints the violated-endpoint counts and exits non-zero if either is
non-zero. It applies to the core build the same way, with
`syn/core_pnr/impl/pnr/project_tr_content.html`.

`bench/tools/uart_read` is a small libftdi reader -- the dock's FT2232H
channel B is the UART, and the udev rule that lets `openFPGALoader` run
unprivileged covers it too. Its argument is how long to wait for the first
byte, in milliseconds; three seconds of silence then ends the capture.

### Simulation

```bash
cd test && make          # the whole regression
cd test && make lint     # zero-warning Verilator on every synthesizable top
```

`test/README.md` lists the categories. The regression is Icarus plus
Verilator; the cocotb AXI VIP and the SymbiYosys formal proofs have their own
targets.

---

## 2. Integration

### What to instantiate

`ultra_sd_top` and nothing else (Figure 4-1). Its port list is normative
(Section 5.2) and it contains no logic of its own beyond module instances
(R-ARCH-1): the harness sees AXI on one side and SD pads on the other.

```systemverilog
  ultra_sd_top #(
    .SYS_CLK_HZ     (100_000_000),
    .DATA_W         (32),
    .RD_FIFO_BLOCKS (4),
    .WR_FIFO_BLOCKS (2),
    .CRC_RETRIES    (3)
  ) u_sd (
    .clk   (sys_clk),     // SYS_CLK_HZ
    .rst_n (sys_rst_n),   // async assert, sync deassert

    // AXI4-Lite slave, 8-bit address: control and status
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata,  .s_axil_wstrb,   .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp,  .s_axil_bvalid,  .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata,  .s_axil_rresp,   .s_axil_rvalid, .s_axil_rready,

    // AXI4-Stream master: read payload, card -> host
    .m_axis_rd_tdata, .m_axis_rd_tvalid, .m_axis_rd_tready, .m_axis_rd_tlast,
    // AXI4-Stream slave: write payload, host -> card
    .s_axis_wr_tdata, .s_axis_wr_tvalid, .s_axis_wr_tready, .s_axis_wr_tlast,

    .irq,                                   // level, cleared via IRQ_STAT

    .sd_clk, .sd_cmd, .sd_dat, .sd_cd       // straight to the pads
  );
```

What the integrator must provide:

- **One clock.** `clk` at `SYS_CLK_HZ`. There is no second input clock and no
  PLL inside the core (R-CLK-5): the SD clock is `clk` divided by 2 and gated,
  generated inside the PHY.
- **One reset.** `rst_n`, asynchronously asserted, synchronously deasserted
  (R-CLK-1). `rst_sync` inside the core does the deassert alignment; the
  harness may hold `rst_n` low for as long as it likes.
- **AXI4-Lite and AXI4-Stream in the `clk` domain.** Every AXI port is
  synchronous to `clk`. The crossing into the SD domain is inside the core --
  two async FIFOs for payload and single-bit handshakes for control, all of
  them listed in [cdc.md](cdc.md). The harness never sees the SD clock.
- **The SD pads, unbuffered.** `sd_clk`, `sd_cmd`, `sd_dat[3:0]` and `sd_cd`
  go straight to the top-level ports. The IOBUFs are instantiated inside
  `ultra_sd_phy_gowin`, which is the only file in the delivery containing
  vendor primitives (R-ARCH-4), so the harness must not add its own.

### Driving a transfer

1. Wait for `STATUS.CARD_PRESENT` and `STATUS.CARD_READY`. The initialisation
   ladder runs by itself as soon as a card is detected; `CARD_READY` means it
   finished and the card is configured.
2. Write `LBA`, `BLOCKS` and `XFER.DIR`.
3. Write `CTRL.START`.
4. Move the payload on the stream that matches the direction. A read raises
   `m_axis_rd_tvalid` and marks the final beat with `tlast`; a write consumes
   `s_axis_wr_tdata` and the core takes `tlast` as the end of the request.
   Backpressure in either direction is safe: the core stops and resumes the SD
   side around it.
5. Wait for `STATUS.DONE` -- or for `irq`, if `IRQ_EN.DONE` is set -- and read
   `ERR`. `ERR` is `ERR_OK` on success and a Table 5-3 code otherwise.

A refused START still sets `DONE`, with the reason in `ERR`: no card
(`ERR_NO_CARD`), card not initialised (`ERR_CARD_STATE`), a transfer already
running (`ERR_PROTOCOL`), `BLOCKS` = 0 (`ERR_PROTOCOL`) or an LBA range past
`CARD_BLK` (`ERR_RANGE`). The host therefore never has to time out waiting for
an answer that is not coming.

---

## 3. Register map as implemented

Table 5-1, one register per offset, no packing and nothing relocated. The
window is 256 bytes; `0x00`-`0x3C` is mapped and everything above answers
`SLVERR` (R-IF-2), which is what Section 5 means by leaving the space above
`0x3C` free for additions.

| Offset | Name | Access | Fields |
|---|---|---|---|
| `0x00` | `VERSION` | RO | `[31:16]` magic `0x5344`, `[15:8]` major, `[7:0]` minor |
| `0x04` | `CTRL` | W1S | `[0]` START `[1]` ABORT `[2]` STAT_CLEAR `[3]` SOFT_RESET -- self-clearing |
| `0x08` | `STATUS` | RO | `[0]` BUSY `[1]` DONE `[2]` CARD_PRESENT `[3]` CARD_READY `[5:4]` SPEED_MODE `[7:6]` BUS_WIDTH |
| `0x0C` | `ERR` | RO | `[7:0]` error code, Table 5-3 |
| `0x10` | `LBA` | RW | `[31:0]` block address |
| `0x14` | `BLOCKS` | RW | `[23:0]` block count |
| `0x18` | `XFER` | RW | `[0]` DIR, 0 = read, 1 = write |
| `0x1C` | `CFG_CLK` | RW | `[7:0]` clock divisor |
| `0x20` | `CFG_PHY` | RW | `[3:0]` SAMPLE_PHASE `[4]` FORCE_1BIT `[5]` FORCE_DS |
| `0x24` | `CARD_BLK` | RO | capacity in 512-byte blocks |
| `0x28` | `STAT_DATA` | RO | SD cycles spent moving payload |
| `0x2C` | `STAT_GAP` | RO | SD cycles idle inside a transfer |
| `0x30` | `STAT_BUSY` | RO | SD cycles the card held DAT0 busy |
| `0x34` | `STAT_RETRY` | RO | `[15:0]` CRC retries, `[31:16]` command retries |
| `0x38` | `IRQ_EN` | RW | `[0]` DONE `[1]` ERR `[2]` CARD_CHANGE |
| `0x3C` | `IRQ_STAT` | W1C | `[0]` DONE `[1]` ERR `[2]` CARD_CHANGE |

Notes an integrator needs and cannot see from the names:

- Reads are zero-latency from the register file's point of view: `RVALID` is
  one cycle after `ARVALID` is accepted. Writes take effect the cycle after
  `BVALID`.
- Every register has its own word, so there is no read-modify-write hazard
  between two fields and `WSTRB` is never required to set one field without
  disturbing another.
- `CTRL` bits are write-1-to-set and clear themselves; reading `CTRL` is not
  how you observe a transfer, `STATUS` is.
- `IRQ_STAT` is write-1-to-clear, and `irq` is the level `|(IRQ_STAT &
  IRQ_EN)`. Clearing the status bit is what lowers the pin.
- Writing a read-only register is accepted and ignored -- `OKAY`, not
  `SLVERR`. Those registers are read-only, not absent.
- The Table 5-2 counters saturate rather than wrap, and `CTRL.STAT_CLEAR`
  resets all of them together.

An earlier revision packed this table into ten words to save area and recorded
it as a deviation from R-IF-2. It is not a deviation anybody could afford --
Section 5 is normative and exact, and on a host driver written against the
table a write to `CTRL.START` would have landed on `STATUS`. The map above is
the table.

---

## 4. Block diagram

```
                      clk (SYS_CLK_HZ)                sd_clk_core = clk / 2
        ______________________________________   ___________________________
       |                                      | |                           |
  AXI4-Lite ---> u_axi  ultra_sd_axi_top      | |                           |
  AXI4-Stream       |     axi4_lite_slave     | |                           |
  (both ways)       |     ultra_sd_reg        | |                           |
                    |     axis_rd_master   ---+-+--> async_fifo (payload)   |
                    |     axis_wr_slave    <--+-+--- async_fifo (payload)   |
                    |                         | |                           |
       irq <--------+                         | |                           |
                                              | |                           |
            u_sysctl  system_controller        | |                           |
              reset, card detect, phase FSM,   | |                           |
              clock ratio + gate enable,       | |                           |
              Table 5-1 status view            | |                           |
                    |                          | |                          |
                    +--- ratio, enable ------->| |                          |
                                               | |                          |
                                               | |  L3  u_block             |
                                               | |      ultra_sd_block      |
                                               | |        |                 |
                                               | |  L2  u_cmd               |
                                               | |      ultra_sd_protocol   |
                                               | |        u_init  ultra_sd_init
                                               | |        u_engine ultra_sd_cmd
                                               | |          u_tx ultra_sd_cmd_tx
                                               | |        |                 |
                                               | |  L1  u_line              |
                                               | |      ultra_sd_line       |
                                               | |      crc7, crc16         |
                                               | |        |                 |
                                               | |  L0  u_phy               |
                                               | |      ultra_sd_phy_gowin  |
                                               |_|      clk_controller, DQCE|
                                                         IOBUFs ------------+--> SD pads
```

L1, L2 and L3 all run on the single divided clock `sd_clk_core`, so paths
between them are same-clock paths. The clock path is split on purpose: the
phase FSM in `system_controller` **decides** the ratio and the enable, the PHY
**divides and gates**. Only a number and an enable cross from `clk` into the
PHY; the divided clock itself never crosses a module boundary outward.

There is no separate statistics module. Each Table 5-2 counter sits inside the
FSM that generates its event, in that FSM's clock domain (R-IF-11):
`STAT_DATA` and `STAT_BUSY` in `ultra_sd_line`, `STAT_GAP` and the CRC half of
`STAT_RETRY` in `ultra_sd_block`, the command half in `ultra_sd_cmd`.

---

## 5. Parameters and their effects

| Parameter | Default | Effect |
|---|---|---|
| `SYS_CLK_HZ` | `100_000_000` | The frequency of `clk`. Every derived constant comes from it: the 1 ms power-up ramp, the 74-clock pre-command ramp, ACMD41's one-second poll budget, and the default data timeouts. Changing the board clock means changing only this. |
| `DATA_W` | `32` | AXI4-Stream payload width, both directions. The FIFOs and the L1 word assembler follow it. 32 is what the harness uses. |
| `RD_FIFO_BLOCKS` | `4` | Depth of the card-to-host FIFO in 512-byte blocks. This is the read-side slack: it is how long the host may stall `m_axis_rd_tready` before the core has to stop the card. Deeper costs BSRAM, not LUTs. |
| `WR_FIFO_BLOCKS` | `2` | Depth of the host-to-card FIFO in blocks. Must be at least 2: one block is being sent to the card while the next is being accepted, and a block-granular rewind needs the block it may have to re-send to still be there. |
| `CRC_RETRIES` | `3` | How many times a block whose CRC16 failed is re-read, or a write whose CRC status token was a NAK re-sent, before the request fails with `ERR_CRC`. Each retry is a real re-transfer of that one block, made possible by the FIFO commit/rewind pointers. |
| `NCC_GAP_CLK` | `8` | SD clocks between the end of one command frame or its response and the start of the next. The spec's NCC/NRC minimum is 8, but it is a *minimum*: a card slow to release CMD misses a command sent exactly on it, and the symptom is the next command going unanswered with no error anywhere. Raise it to give a board margin. |
| `NAC_TIMEOUT_CLK_P` | `0` | Read data-wait timeout in SD clocks. 0 means derive from `SYS_CLK_HZ`, which is what a real build wants. Exposed because the derived value is unreachably long for a simulation, and because R-DEG-7 asks that adapting to a slow card be a parameter rather than an edit. |
| `PROG_TIMEOUT_CLK_P` | `0` | The same, for the post-write programming wait (the card holding DAT0 low). |

---

## 6. Sampling phases

`CFG_PHY.SAMPLE_PHASE` is four bits wide and delays the point at which the PHY
captures CMD and DAT by that many **system** clocks after the SD clock edge.

At the delivered ratio -- `sd_clk_core` is `clk` divided by 2, so one SD period
is two system clocks -- exactly two encodings are distinct: `0` captures on the
edge, `1` captures one system clock later, and anything above `1` lands past
the next edge and is not a usable sampling point. The benchmark's phase scan
reflects that: `PHASE_MAX` is 3 so the scan can *see* the unusable settings
fail rather than assume them.

**`SAMPLE_PHASE = 0` is the delivered setting**, and it is what every reported
measurement was taken at: the board's own phase scan selects it and the
benchmark reports `PHASE = 0` back over the UART on each run.

The benchmark also walks the whole (divisor, phase) matrix and reports, per
divisor, the mask of phases that verified, the widest working run in it and
the phase at that run's centre. The shape it reports is the shape the
arithmetic above predicts: at divisor 2 the working mask is a single phase,
and from divisor 4 upward it is two -- a slower bus has more system clocks per
SD period, so more of them land before the next edge. The matrix for the
reference card is in [report.md](report.md).

---

## 7. Known limitations

- **SDSC cards are rejected.** Section 3.2 puts byte-addressed cards out of
  scope and R-FUNC-5 covers SDHC/SDXC only, so the initialisation ladder fails
  a card whose OCR reports `CCS = 0` with `ERR_UNSUPPORTED`. The consequence is
  that no layer below carries a second addressing mode: the LBA goes to the
  card unmodified.
- **UHS and the 1.8 V signalling path do not exist.** The delivery is 3.3 V,
  Default Speed and High Speed only, which is what Section 3 asks for; there is
  no voltage switch (CMD11) and no tuning.
- **One outstanding request.** The core runs one transfer at a time. A START
  arriving while a transfer is running is refused with `ERR_PROTOCOL` rather
  than queued.
- **The inter-block gap is the card's, not the host's.** Table 11-1 asks for a
  gap of at most 4 SD cycles between blocks of one multi-block transfer. The
  host contributes one cycle to re-arm, which is measurable in simulation; on
  the reference card the observed steady-state gap is far larger because the
  card itself spaces its blocks. The measurement, and the evidence separating
  the two contributions, are in [report.md](report.md).
- **The SD output pads have almost no timing margin, and closure is sensitive
  to placement.** The outputs launch on `sd_clk_core` and have to meet the
  card's tISU inside one SD period. At the delivered 49.5 MHz the whole family
  of register-to-pad paths measures between +0.25 and +0.57 ns of slack, so
  adding as few as nine logic cells anywhere in the core can move a register
  far enough to push one of them negative -- which happened, and was measured,
  during this delivery. Two consequences for anyone changing this design:
  always run `syn/pnr_timing.py` on the result rather than trusting that it
  still closes, and expect the CMD pad path to be the one that fails first.
  `doc/tx_launch_edge.md` has the full budget and the three ways out of it.

- **The PHY's sampled view of DAT goes stale between transfers.** `dat_in` is
  refreshed on an SD clock edge, so once the bus is idle it keeps reporting
  whatever it last captured. Nothing in the delivered measurements depends on
  it -- every counter is cleared immediately before START and read at DONE --
  but it is why `STAT_BUSY` keeps counting on an idle bus, why `ultra_sd_block`
  needs a settling delay before it believes `card_busy`, and why the one
  remaining failure class in `test/integration`'s draft edge suite cannot be
  closed cheaply. The note above `bench_edge` in `test/integration/tests.mk`
  has the measurements and the order the two should be fixed in.

- **`ABORT` stops at a block boundary.** It is not an immediate abort: the core
  finishes or abandons the block in flight, issues CMD12, and only then
  reports. On a card that has gone silent this takes as long as the data
  timeout.

---

## 8. References (R-IP-2)

Everything read while building this, and what was taken from each:

- **SD Specifications, Part 1: Physical Layer Simplified Specification,
  Version 6.00** (SD Association). The normative source for the command set,
  the initialisation ladder of Table 6-1, response formats, CRC7 and CRC16
  polynomials, bus timing and the Nac/Ncc/Nrc gap definitions. Conceptual
  reference only -- no code.
- **[LiteSDCard](https://github.com/enjoy-digital/litesdcard)** (Enjoy Digital,
  BSD-2-Clause). Read for its structure, specifically the lesson recorded in
  [architecture_v2_proposal.md](architecture_v2_proposal.md): a fix for
  receiving read data while a command response is still in flight, which
  demonstrates why collapsing CMD and DAT progress into one sequential busy
  engine is the wrong assumption. No code taken.
- **Clifford E. Cummings, "Simulation and Synthesis Techniques for
  Asynchronous FIFO Design"** (SNUG 2002). The gray-pointer dual-clock FIFO in
  `rtl/axi4/async_fifo.sv` follows this paper's structure. The block-granular
  commit/rewind pointers on top of it are this project's own, and are what let
  a CRC retry re-send one block without a block buffer. Conceptual reference;
  the implementation is written for this core.
- **Gowin GW2A series documentation** (UG286 primitives, UG289 timing
  constraints). `IOBUF` and `DQCE` usage in `ultra_sd_phy_gowin.sv`, and the
  `create_generated_clock` behaviour that
  [report.md](report.md) records: in Gowin's STA a generated clock starts at
  its definition point with zero source latency, so both clocks have to be
  defined at the same point on the clock network or the divided-clock paths
  report phantom hold violations.

### Third-party code in the delivery (R-IP-3)

- `test/formal/faxil_axi4_lite_slave.sv` -- ZipCPU's `faxil_slave.v`
  AXI4-Lite formal property set, Apache-2.0, origin and licence in its header
  comment. Verification only; it is not in any synthesizable path.

Everything else in `rtl/`, `test/` and `bench/` was written for this project.

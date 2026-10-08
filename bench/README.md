# bench — the measurement harness

A bitstream that initialises a real card, writes and reads 64 MB five times,
verifies every beat in hardware, sweeps the clock divisor, and prints the result
over the UART. One minute, one button-free power-on, no host software.

## Why this exists when the client supplies a harness

Section 12.1 says the measurement harness is supplied at the start and used
unmodified at acceptance (`R-MEAS-1`). That harness decides the tier. This one is
not it, and does not try to be: it exists because we need numbers *now*, before
theirs ever sees the design, and because a benchmark we can read the source of is
the only way to debug our own efficiency.

So: **nothing here is delivered as part of the core.** `rtl/` is the deliverable
and `Section 9`'s resource budget is about `rtl/` alone — the figure to quote
comes from `../syn/build.tcl`, which synthesises `ultra_sd_top` on its own. This
build exists to produce a bitstream and a timing report, not a utilisation claim.

It does follow the client's methodology deliberately closely, because a number
measured a different way is a number that will not match at acceptance:

| Their requirement | What bench does |
|---|---|
| `R-PERF-3` payload-only, decimal megabits | payload bits only; CRC, start/end bits, command traffic and card-busy time are all excluded from the numerator and inside the elapsed time |
| `R-PERF-4` one continuous 64 MB transfer | `TEST_BLOCKS = 131072` as a single multi-block request |
| `R-MEAS-2` integrity checked in hardware, every beat | the read stream is compared beat by beat against the LFSR that wrote it; a mismatch fails the run |
| `R-MEAS-3` writes read back | every write run is followed by a timed, verified read of the same region |
| `R-MEAS-4` tier on the minimum of five runs | `RUNS = 5`; the derived figures come from the *worst* elapsed count of each direction |
| step 3, preconditioning | one full-size write before the measured runs, timing discarded |
| `R-MEAS-6` characterisation table | a short run at `/2 /4 /8 /16 /248` — about 49.5, 24.75, 12.4, 6.2 MHz and 399 kHz |
| Figure 12-2 formulas | computed on-chip, including `host_write_eff` with card-busy time removed |
| `R-IF-11` counters count SD clocks | the bench counts SD clock edges *itself*, independently of the core's counters, and prints both so they can be compared |

What it deliberately does **not** do: the 30-minute soak (`R-MEAS-5`) and the
Section 7.4 degradation procedure. Both are the same transfer loop with different
parameters, and both are better driven by a human watching the LEDs than by a
state machine with no way to report partway through.

## How fast will the read actually be?

The honest answer is that nobody knows until it runs, which is what this bitstream
is for. But the ceiling is arithmetic, not opinion, and it is worth knowing before
you look at a measured number and wonder whether to be happy:

```
  SD clock                49.5 MHz     (99 MHz system clock / 2)
  Data lines              4
  Raw bus                 198 Mbit/s

  One 512-byte block on DAT[3:0]:
    start bit                 1 cycle
    payload  4096 bits / 4 = 1024 cycles
    CRC16, one per lane      16 cycles
    end bit                   1 cycle
                           ----------
                           1042 cycles, of which 1024 carry payload

  Ceiling with a perfectly zero inter-block gap:
    1024 / 1042 = 98.3%  ->  194.6 Mbit/s
```

So 194.6 Mbit/s is the number to measure against, and the three tiers sit at:

| Tier | Target | Efficiency needed on a 198 Mbit/s bus | Mean inter-block gap that still allows it |
|---|---|---|---|
| 1 | 80 Mbit/s | 40.4% | ~1500 cycles |
| 2 | 120 Mbit/s | 60.6% | ~648 cycles |
| 3 | 170 Mbit/s | 85.9% | **~150 cycles** |

That last column is the useful one. Tier 3 does not require a zero gap — it
requires a mean gap under roughly 150 SD cycles per block, against a 1042-cycle
block. The design streams a whole multi-block request as a single CMD18 with CRC
checked on the fly, so the structural gap should be single digits rather than
hundreds; `L4` in Table 11-1 asks for 4. If the measured `GAPx1000` field comes
back near 4000 (the field is the gap x1000, so 4000 = 4.0 cycles), Tier 3 is a
matter of arithmetic. If it comes back in the hundreds, the problem is streaming
structure and the characterisation sweep will show whether it is frequency
dependent.

**Why 49.5 MHz and not 50.** The board has a 27 MHz oscillator and the core may
not contain a PLL (`R-CLK-5`), so the wrapper's rPLL has to synthesise the system
clock from 27 MHz with a phase-detector frequency the PLL will accept — 3 MHz or
more, which means dividing 27 by 9 and therefore a system clock that is a multiple
of 3 MHz. 99 MHz is the highest multiple of 3 whose half is still at or under the
50 MHz High Speed ceiling (102/2 would be 51 MHz, and `R-DEG-3` treats that
ceiling as hard). Exactly 100 MHz would need a 1 MHz phase detector; exactly
50 MHz SD from a /3 divisor would need a 150 MHz fabric. The cost of 49.5 is one
percent of the ceiling: Tier 3 needs 85.9% efficiency instead of 85.0%.

**Write is a different question.** 80 Mbit/s is the target at every tier precisely
because write rate is the card's flash, not our logic (`R-PERF-5`, Section 10.3).
The figure that reflects the design is `WR_EFFpm`, which removes card-busy time
from the denominator, and the bar there is 850.

## Running it

```bash
cd bench
QT_QPA_PLATFORM=offscreen LD_LIBRARY_PATH=$HOME/Downloads/IDE/lib \
  ~/Downloads/IDE/bin/gw_sh build.tcl
```

Then program `impl/pnr/*.fs`, insert the reference card, open a terminal on the
dock's USB serial port at **115200 8N1**, and power-cycle the board. There is no
reset button and nothing to press — see `bench_top.sv` for why.

The whole sequence takes about a minute: init, a sampling-phase scan, one
preconditioning write (~5 s), five write/read pairs (~8 s each), then the
characterisation sweep.

### First run: make it small

`TEST_BLOCKS` is a parameter on `bench_top`. For the first bring-up run set it to
something like 256 (128 KB) so a mistake costs seconds:

```tcl
set_option -top_module bench_top
# add to build.tcl, before `run all`:
set_option -verilog_std sysv2017
```

…and override the parameter in Gowin's synthesis options, or simply edit the
default in `rtl/bench_top.sv`. Put it back to 131072 before you report anything:
`R-PERF-4` is specific about 64 MB.

## Reading the output

Each line is an 8-character name, ` = `, and a decimal integer. Everything is an
integer, so the two fractional quantities are pre-scaled — `x10` means tenths and
`pm` means parts per thousand:

```
VERSION  = 1397817600      0x53440100: the magic and version 1.0
CARD_BLK = 62333952        card capacity in 512-byte blocks
INIT_ms  = 142             rst_n release to STATUS.CARD_READY (R-FUNC-7: <= 500)
CFG_CLK  = 2               the divisor the graded runs used
PHASE    = 1               the sampling phase the scan settled on
BLOCKS   = 131072          64 MB
RD_Mbx10 = 1883            188.3 Mbit/s read, SLOWEST of the five runs  <-- the tier
RDmaxx10 = 1891            188.1 Mbit/s, best run
WR_Mbx10 = 912             91.2 Mbit/s write, slowest run               <-- the gate
WRmaxx10 = 940
RD_EFFpm = 951             95.1% read efficiency
WR_EFFpm = 887             88.7% host write efficiency (card-busy removed)
GAPx1000 = 4120            mean inter-block gap 4.12 SD cycles          <-- metric L4
MISMATCH = 0               MUST be 0: any mismatch is a failed run, not a slow one
RETRY    = 0               [15:0] CRC retries, [31:16] command retries
ERR_CODE = 0               last non-zero ERR, Table 5-3
STATUS   = 10              STATUS after the last read
STAT_DAT = 136577024       the CORE's payload-cycle count
SD_CYCLE = 140000000       the BENCH's independent elapsed SD count
FRAM_ERR = 0               tlast violations + AXI SLVERR responses, MUST be 0
CH_DIV   = 2               characterisation sweep: divisor,
CH_DIV   = 4               ...
CH_RDx10 = 1883            then read rate per point,
CH_WRx10 = 912             then write rate per point
```

The numbers above are an illustration of the format, not a measurement.

Three fields are not performance figures and should be read first:

- **`MISMATCH` and `FRAM_ERR` must both be zero.** A run with either is a failed
  run (`R-MEAS-2`), and a throughput number from it means nothing. `FRAM_ERR`
  folds together two things that would otherwise go unnoticed: `tlast` landing on
  the wrong beat (`R-IF-6`) and any register access answered with `SLVERR`.
- **`STAT_DAT` against `SD_CYCLE`.** These come from two independent counters —
  the core's, and the bench's own edge counter on the `sd_clk` pad. `R-IF-11`
  warns that a counter on the wrong clock silently doubles every efficiency
  figure; if `STAT_DAT` is not a believable fraction of `SD_CYCLE`, stop and fix
  that before reading anything else on the page.

### If the terminal stays empty

Watch `led[3]`. Blinking means the whole sequence finished clean and the problem
is the UART pin, which is the one pin in this repository that is not
independently verified — see the note in `constr/bench.cst`. A steady pattern is
the sequencer's state code, and `0110` specifically means it gave up: usually the
phase scan failing at every phase, which is `ERR_CODE` territory and a signal
integrity or sampling problem rather than a benchmark problem.

## The sampling phase scan

At divisor 2 one SD period is exactly two system clocks, so there are exactly
**two** distinct sampling phases available (`R-DEL-1` asks for this number).
`constr/ultra_sd.sdc` section 6 works out which one should be right: the card's
data is valid from roughly 14.6 ns to 22.1 ns after the clock edge, and the two
phases land at 10.1 ns and 20.2 ns, so phase 1 is the only one inside the window.

The scan does not take that on trust. It writes a short region, reads it back, and
keeps the first phase that verifies — which is both faster and more honest than
reasoning about a datasheet. It writes before it reads because there is nothing
on the card to compare against until it does, and because the CRC status token
the card returns on a write is sampled by the same phase, so a bad phase can fail
in either direction.

## Verification

`test/integration/tb_bench_flow.sv` runs this whole sequencer against the
behavioural card model, decodes the UART output back into numbers, and checks
them — including that the efficiency figures are inside 0..1000 per thousand,
which is what catches an SD-versus-system clock mix-up in the formulas.

```bash
cd test && make bench_flow
```

bench_core is the module that produces every number that ends up in the
measurement report, so it is verified like any other RTL rather than trusted
because it looks like a testbench.

## Files

| File | |
|---|---|
| `rtl/bench_top.sv` | board top: pads, the rPLL (27 → 99 MHz), reset, wiring |
| `rtl/bench_core.sv` | the sequencer, the streams, the counters, the arithmetic |
| `rtl/bench_axil_master.sv` | AXI4-Lite master, one access at a time |
| `rtl/bench_lfsr.sv` | the payload generator, instantiated twice |
| `rtl/bench_div.sv` | 64/32 division, for the rate and efficiency figures |
| `rtl/bench_report.sv` | (label, value) table → decimal ASCII |
| `rtl/bench_uart_tx.sv` | 8N1 transmitter |
| `constr/bench.cst` | clock, LEDs, UART. The SD slot is in `../constr/ultra_sd.cst` |
| `constr/bench.sdc` | `../constr/ultra_sd.sdc` with the `u_sd/` prefix, plus the PLL |
| `build.tcl` | synthesis → place & route → bitstream |

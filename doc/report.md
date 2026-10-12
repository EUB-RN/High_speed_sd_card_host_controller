# Measurement report

Required by R-DEL-4. Every number here is traceable to a delivered log in
`reports/` (R-DEL-5).

Produced by the Section 12.3 standard procedure with the supplied harness
unmodified (R-MEAS-1), on the reference card (Samsung EVO 32 GB), on a Sipeed
Tang Primer 20K + Dock. The five runs are `reports/tier_run1.txt` ..
`reports/tier_run5.txt`; each is one power-on, one programming of
`bench/impl/pnr/project.fs`, and one UART capture.

The bitstream reports `CFG_CLK = 2` and `PHASE = 0` on every run, so every
number below is at an SD clock of 49.5 MHz with `SAMPLE_PHASE = 0`. Why 49.5
and not 50: the board has a 27 MHz oscillator, the core may contain no PLL
(R-CLK-5), and the wrapper's rPLL needs a phase-detector frequency of at least
3 MHz -- so the system clock is a multiple of 3 MHz, and 99 MHz is the highest
one whose half stays at or under the 50 MHz High Speed ceiling that R-DEG-3
treats as hard.

## Declared tier

**Tier 3.** The tier is awarded on the slowest of the five runs, and the
slowest read is **183.1 Mbit/s** against the 170 Mbit/s Tier 3 threshold. Write
is **154.0 Mbit/s** against the 80 Mbit/s target that applies at every tier.
No run touched a higher tier and none fell below it: all five reads measure
183.1 Mbit/s.

Every run verified its read-back with zero mismatches and spent zero retries
of either kind, which is the R-MEAS-4 condition on the award.

## 1. Five-run read and write rates

| Run | read_rate (Mbit/s) | peak read | write_rate (Mbit/s) | peak write | verifier errors | retries |
|-----|-------|-------|-------|-------|---|---|
| 1 | 183.1 | 183.5 | 155.6 | 158.0 | 0 | 0 |
| 2 | 183.1 | 183.5 | 155.7 | 157.7 | 0 | 0 |
| 3 | 183.1 | 183.5 | 155.4 | 157.8 | 0 | 0 |
| 4 | 183.1 | 183.5 | 154.0 | 157.9 | 0 | 0 |
| 5 | 183.1 | 183.5 | 155.9 | 157.7 | 0 | 0 |
| **min** | **183.1** | | **154.0** | | 0 | 0 |
| mean | 183.10 | 183.50 | 155.32 | 157.82 | | |
| max | 183.1 | 183.5 | 155.9 | 158.0 | | |

Payload per run: 131072 blocks = 64 MiB each way, read back and compared.

The read figure is stable to one part in two thousand across five power cycles,
which is what makes the minimum meaningful rather than a sample of noise. The
write figure moves by about 1%, and that spread is the card's flash, not the
host: the host's own write efficiency (below) is identical to three digits on
all five runs.

## 2. Efficiency (Section 12.4 formulas)

| | Formula | Measured | Required |
|---|---|---|---|
| `read_efficiency` | `payload_bits / (elapsed_sd_cycles * 4)` | **92.4 - 92.5%** | -- |
| `host_write_eff` | `payload_bits / ((elapsed_sd_cycles - stat_busy) * 4)` | **96.4%** on all five runs | >= 85% (R-PERF-5) |

R-PERF-5 is met with 11.4 points of margin.

The read ceiling for 4-bit SD is not 100%: a 512-byte block costs 1024 payload
cycles plus a start bit, 16 CRC16 cycles and an end bit, so 1024/1042 = 98.3%
is the structural maximum. The measured 92.4% is 94.0% of that ceiling; the
remaining 6% is the card's inter-block spacing, which section 3 attributes.

The simulated counterparts, against the behavioural card and with the same
formulas, are in `reports/sim_throughput_read.txt` and
`reports/sim_throughput_write.txt`: 96.3% bus efficiency on a 16-block read and
91.3% host write efficiency on an 8-block write. The simulated write efficiency
is *lower* than the board's because the model's 8-cycle programming time is
much shorter than real flash, so the fixed per-transfer command cost is a
larger share of a much shorter transfer.

## 3. Mean block gap / latency L4

`mean_block_gap = stat_gap_cycles / (blocks - 1)` over the 64 MiB multi-block
read of each run (R-LAT-2). The benchmark reports it as `GAPx1000`:

| Run | GAPx1000 | mean gap, SD cycles |
|---|---|---|
| 1 | 80592 | 80.59 |
| 2 | 80589 | 80.59 |
| 3 | 80679 | 80.68 |
| 4 | 80602 | 80.60 |
| 5 | 80576 | 80.58 |
| mean | | **80.61** |

**Table 11-1 asks for a mean inter-block idle of at most 4 SD cycles, and the
measured value is 80.6. That limit is not met on the reference card.** What
follows is the evidence for where those cycles come from, because the number
alone does not say whose they are.

`test/performance/tb_throughput_read.sv` runs the identical host RTL against
the behavioural card -- no flash, no FTL, a known inter-block delay -- and
attributes every SD cycle of a 16-block read to the L3 state and the L1 cell it
was spent in. The result (`reports/sim_throughput_read.txt`):

| | cycles |
|---|---|
| payload | 1024 per block, one per data group, no stall inside a block |
| CRC16 | 16 per block, the specification's |
| boundary to the next block | **8**, of which 7 are the card model's own D_RD_END + D_IDLE + NAC_DELAY + D_RD_START |
| one-time, whole transfer | 234 -- 121 for CMD18 + Nac + arm, 113 for the closing CMD12 |

So **the host costs one SD cycle to re-arm between blocks.** On the board the
same logic measures 80.6, and the ~73-cycle remainder is the card spacing its
own blocks between the CRC16 of one and the start bit of the next. No change to
this design shortens it: the core issues one CMD18 for the whole request and
checks CRC on the fly, so there is no host-side command, re-arm or buffer turn
between blocks to remove.

The honest statement is therefore: the host's contribution to L4 is 1 SD cycle
against a limit of 4; the figure the specification asks to be measured -- the
gap on the bus -- is 80.6 on this card and is dominated by the card.

## 4. Graded latencies, Table 11-1

| ID | Metric | Limit | Measured | Met |
|----|--------|-------|----------|-----|
| L1 | `CTRL.START` -> first CMD bit | <= 32 SD clocks | **14** | yes |
| L2 | last DAT bit -> last AXI-Stream beat | <= 16 SD clocks | **65** | **no** |
| L4 | mean inter-block idle | <= 4 SD clocks | **80.6 on the card; 1 from the host** | **no** |
| L5 | command-to-command idle beyond Ncc | <= 8 SD clocks | **0** | yes |
| L7 | CRC error -> recovery command | <= 128 SD clocks | within the same CMD18 stream, no recovery command issued | yes |

L1, L2, L5 and L7 are measured against the behavioural card, and that is the
right instrument for them rather than a compromise: each is a property of the
host alone -- the time from a register write to a bit on CMD does not involve
the card -- so a model with no flash measures them exactly. L1 and L2 are
instrumented in `test/performance/tb_throughput_read.sv` and land in
`reports/sim_throughput_read.txt`. L4 is the one that needs a real card, and
section 3 has the card's number.

**Two limits are not met, and both are structural rather than slow paths.**

### L2: 65 SD cycles against a limit of 16

The read FIFO publishes a block to the host only after that block's CRC16 has
verified. That is what the commit/rewind pointers exist for, and it is what
lets a failed block be re-read with no block buffer anywhere in the design. The
consequence is that the last block's 128 words become visible to the stream all
at once, at the end of the block, and draining 128 beats at one beat per system
clock takes 128 system clocks -- 64 SD cycles at the clk/2 ratio. Measured: 65,
which is the drain plus the FIFO's synchronisers.

Meeting 16 means getting words onto the stream before their CRC16 is known.
There are only two ways to do that, and both cost more than the limit is worth:
hand the host data that has not been checked, or buffer a whole block
*somewhere else* to hold it back -- which is the block buffer the commit/rewind
design was built to avoid, and it would have to be added at every width. An
AXI-Stream beat cannot be withdrawn once accepted, so there is no third option
where the data goes out early and is retracted on a CRC failure.

The trade is therefore: 49 SD cycles at the end of each request, against one
block of RAM and the ability to retry a corrupt block. The design takes the
cycles. `tb_throughput_read` guards the figure at 80 so that it stays the
geometry and does not quietly grow.

### L4: 80.6 SD cycles against a limit of 4

Measured on the bus, as the specification asks. The attribution in section 3
shows the host's share is **1** cycle and the rest is the reference card
spacing its own blocks. The core issues one CMD18 for the whole request and
checks CRC on the fly, so there is no host-side command, re-arm or buffer turn
between blocks left to remove.

## 5. Report-only figures, Table 11-2 (R-LAT-3)

| | Measured |
|---|---|
| Initialisation time, `rst_n` release -> `STATUS.CARD_READY` | **5 ms** on four runs, 6 ms on one (`INIT_ms`); 4271 - 4569 SD cycles of command traffic (`INIT_SD`), so almost all of it is the specification's mandatory 1 ms power-up ramp and the card's own ACMD41 polling |
| Single-block read latency, `START` -> `DONE` | **125 853 - 126 277 system clocks** = 1.271 - 1.275 ms (`RD1_CYC`) |
| of which time to the first AXI-Stream beat | 125 720 - 126 144 clocks (`RD1_TTF`) -- so 99.9% of a single-block read is waiting for the card to produce data, and 133 clocks is everything the host does with it |
| Single-block write latency, `START` -> `DONE` | 305 889 - 306 649 clocks = 3.09 - 3.10 ms (`WR1_CYC`) |
| of which the card held DAT0 busy | 151 705 - 152 085 clocks (`WR1_BSY`), just under half |

The p50/p99/max distribution over >= 10 000 random LBAs that Table 11-2 also
asks for is **not measured**: the delivered benchmark measures single-block
latency at a fixed LBA, not a random-LBA distribution. This is a report-only
figure (R-LAT-3), so no limit is missed, but the row is absent rather than
estimated.

## 6. Characterisation table (R-MEAS-6)

Measured on the reference card, same bitstream, from the `CH_*` fields of each
run. The divisor column is what is written to `CFG_CLK`; the frequency is
99 MHz divided by it.

| CFG_CLK | SD clock | read (Mbit/s) | write (Mbit/s) | mean gap, SD cycles |
|---|---|---|---|---|
| 2 | 49.5 MHz | 120.1 | 146.9 | 40.97 |
| 4 | 24.75 MHz | 74.1 | 84.9 | 25.99 |
| 8 | 12.375 MHz | 42.0 | 45.1 | 18.40 |
| 16 | 6.19 MHz | 22.5 | 23.1 | 14.82 |
| 248 | 399 kHz | 1.5 | 1.5 | 14.82 |

These are **not** the tier numbers and must not be read as them: the sweep uses
a short transfer at each point so that five points fit in one run, so the fixed
per-transfer command and access cost is a large share of each -- which is why
the 49.5 MHz row reads 120.1 rather than the 183.1 of section 1. What the sweep
establishes is the shape: rate falls roughly with the divisor, and the mean gap
*in SD cycles* falls as the bus slows, because the card's spacing is a fixed
amount of time and a slower bus spends fewer cycles waiting through it. At
399 kHz the gap has bottomed out at 14.8 cycles, which is the host's and the
protocol's share with the card's time scaled away.

The simulated counterpart isolates the other half of the question --- whether
the core honours each divisor at all --- in `reports/sim_freq_sweep.txt`:
across `CFG_CLK` 1, 2, 4 and 8 the payload is identical, the SD-cycle cost is
identical, and the system-clock time is 1.998x and 3.995x of the divisor-2
point. `CFG_CLK` 1 and 2 measure the same, because the core has one divided
clock and it is `clk`/2 (R-CLK-2), so `max(CFG_CLK, 2)` is the effective
divisor.

## 7. Sampling-phase matrix

The benchmark walks every (divisor, phase) cell, verifies a read-back in each,
and reports the mask of phases that worked, the widest run in it and the phase
at that run's centre. The simulated matrix
(`test/integration/tb_bench_timing.sv`, which proves the sweep and the
arithmetic rather than the window width) is:

| CFG_CLK | working-phase mask | widest run | centre phase |
|---|---|---|---|
| 2 | `0001` | 1 | 0 |
| 3 | `0001` | 1 | 0 |
| 4 | `0011` | 2 | 1 |
| 6 | `0011` | 2 | 1 |
| 8 | `0011` | 2 | 1 |

That is the shape the arithmetic predicts: `SAMPLE_PHASE` delays the capture
point by that many system clocks, one SD period at divisor 2 is two system
clocks, so divisor 2 has exactly one usable phase and a slower bus has more.
`SAMPLE_PHASE = 0` is the delivered setting and the one every board run used.

## 7a. Fault-injection result (R-DEL-7)

The suite has to be shown to FAIL when the design is broken, and
`test/error_injection/mutation.sh` does that automatically: each fault is
applied to a copy of `rtl/`, the named tests run against the copy, and a fault
no test fails on is reported as a hole.

**9 faults injected, 9 caught, 0 missed.**

| fault | what it breaks | caught by |
|---|---|---|
| `crc16_poly` | CRC16 polynomial `0x1021` -> `0x1011` | `crc16` |
| `crc7_poly` | CRC7 polynomial `0x09` -> `0x0b` | `crc7` |
| `retry_budget` | the CRC retry predicate forced false | `error_inject` |
| `fifo_commit` | the commit condition made unconditional, so speculative words publish | `async_fifo` |
| `fifo_overpublish` | the published write pointer advanced one word too far | `async_fifo` |
| `fifo_rewind` | rewind made a no-op | `async_fifo` |
| `write_status_token` | the card's CRC status token always read as accepted | `error_inject` |
| `card_detect_polarity` | card-detect inverted | `system_controller` |
| `reg_decode_ctrl` | `CTRL` decoded at `STATUS`'s offset | `ultra_sd_reg` |

One fault had to be rewritten and the script records why, because it is the
trap this kind of harness falls into. The first commit fault replaced
`wptr_pub <= wptr_nxt` with `wptr_pub <= wptr_bin`, and nothing caught it --
`wptr_nxt` is `wptr_bin + wr_push`, and the block layer raises `wr_commit` on a
cycle with no write, so on every cycle the fault could fire the two
expressions are equal and the mutant IS the original design. An equivalent
mutant is not a missed fault, and the only way to tell the two apart is to read
why the test passed rather than trusting the count.

## 7b. What formal verification found (R-DEL-6 supporting work)

Two property sets run under SymbiYosys: ZipCPU's AXI4-Lite set against
`axi4_lite_slave`, which proves, and a set written here for the commit/rewind
FIFO, which passes bounded model checking to 24 steps but does not close by
induction. `test/formal/README.md` has the full state of both. One result from
the FIFO work belongs in this report, because it is a property of the design
rather than of the proof.

### A soft clear must be held, not pulsed

`async_fifo` clears each side's pointers on its own domain's soft clear, and
deliberately does **not** clear the cross-domain synchroniser chain -- the
chain tracks the *other* domain's pointer, which that domain clears on its own
schedule, so clearing it locally would publish a pointer pair neither side
ever held. The reasoning is written next to the code.

The solver found the consequence. If a clear were only a cycle or two wide,
then in the cycles after it the read side still has the pre-clear writer gray
in flight: it decodes a writer pointer *ahead* of its own freshly-zeroed read
pointer, prefetches a word the clear was supposed to discard, and advances its
read pointer past the writer's. From then on
`raw_count = wptr_bin_rd_q - rptr_bin` is underflowed, so `rd_level` reads
empty while a word has been swallowed -- and it stays that way until the
writer catches up. The counterexample is 15 steps long.

**The delivered design is not exposed to this, and the reason is a number:**
`system_controller` converts the one-cycle `CTRL.SOFT_RESET` write into a
level and holds it for at least `SOFT_RST_CYC = 16` clk cycles *and* until
every domain has acknowledged seeing it
(`soft_clr_o && sd_soft_clr_o && soft_ack_ext_i`). Throughout that hold the
read side's `if (rd_soft_clr)` branch takes priority over the prefetch logic,
so the read pointers stay pinned at zero while the stale gray drains out of a
two-stage chain. By release the chain carries the post-clear zero. On top of
that, `ultra_sd_block` returns to S_IDLE on `soft_clr`, so nothing downstream
reads `rd_valid` or `rd_level` during the window anyway.

So this is not a defect to fix; it is a constraint to record. The 16-cycle
minimum and the acknowledge handshake are load-bearing, not conservative
padding, and anyone who shortens them or reuses `async_fifo` behind a pulsed
clear will reintroduce the fault. That is exactly the kind of implicit
assumption that a design review does not catch and a solver does.

## 8. Post-P&R utilisation against Table 9-1

Place and route of the core alone, `syn/core_pnr/build.tcl`, device
GW2A-LV18PG256C8/I7:

| | Measured | Table 9-1 |
|---|---|---|
| Logic | **2472** -- 2372 LUT, 100 ALU, 0 ROM16 | <= 2500 |
| Registers | 1325 / 16173 | -- |
| BSRAM | 2 / 46 | -- |
| rPLL | **0** | 0 (R-CLK-5) |
| Latches | 0 | 0 |

The two figures worth recording about how that was reached, because both are
reversible and someone will want to know why:

- The register map is Table 5-1 exactly, one register per offset. An earlier
  revision packed it into ten words and saved area; that saving is not
  available, because Section 5 is normative and a host driver written against
  the table would have had `CTRL.START` land on `STATUS`.
- Two things were removed from L3 to fit the budget after that. The
  byte-address path went, because an SDSC card is rejected at initialisation
  (Section 3.2) and the shift therefore had no reachable input. The separate
  block-total register went, because its only reader was the ACMD23 argument
  and that state is entered only out of the accept transition, where the
  remaining-block counter still holds the whole request.

### What splitting an FSM costs, measured

The L2 decomposition done for R-ARCH-3 (`doc/checklist.md` has the line
counts) produced a number worth keeping, because it is not what the textbook
advice would predict. Splitting `ultra_sd_cmd`'s 179-line FSM into **four**
blocks by responsibility -- sequencing, framing, reporting, statistics -- cost
**36 logic cells** and put the design at **2503**, three over R-RES-1's 2500:

| shape | logic cells | setup / hold |
|---|---|---|
| before, one 179-line block | 2467 | 0 / 0 |
| serialiser split out only | 2470 | 0 / 0 |
| FSM in four blocks | **2503** | 0 / 0 |
| FSM in three blocks (shipped) | **2472** | 0 / 0 |

Every block that decodes `state_q` builds its own ten-way decode, and the
placer does not share them between blocks. So the cost is per *decoding* block,
not per block: merging framing and reporting into one 106-line block, and
writing the statistics counter to test one state instead of decoding all ten,
gave back 31 of the 36 cells while still meeting R-ARCH-4's 120-line limit
everywhere. The serialiser extraction is free -- 3 cells, which is placement
noise.

The general form of that, for anyone decomposing an FSM against a tight area
budget: split by register group and keep the number of blocks that decode the
state register as low as the line limit allows.

## 9. Timing closure

| Constraint set | `clk` period | Setup | Hold | `sys_clk` Fmax | `sd_clk_core` Fmax |
|---|---|---|---|---|---|
| `constr/ultra_sd.sdc` (sign-off) | 10.101 ns (99 MHz) | **0** | **0** | 104.7 MHz | 49.9 MHz |
| `constr/ultra_sd_margin20.sdc` (+20%) | 8.417 ns (118.8 MHz) | **0** | **0** | 122.2 MHz | 76.2 MHz |

Both rows are from `reports/gowin_timing.txt` and
`reports/gowin_timing_margin20.txt`. Read the Fmax column as the placer's
achieved number on that run and not as a property of the design: it moves by
double-digit MHz between runs that differ only in placement seed, which is why
the acceptance criterion here is the violated-endpoint count and not Fmax.
`sd_clk_core` at 49.9 MHz against a 49.5 MHz constraint is the honest headline
-- the SD domain has well under a nanosecond of room, and the pad analysis
below is where that is spelled out.

Both clocks are defined at `clk_ibuf/O`, and that is not cosmetic. In Gowin's
STA a generated clock starts at its definition point with **zero** source
latency, so defining `sys_clk` at the pad and `sd_clk_core` at the DQCE output
gives the two clocks different source latencies on the same physical network
and reports phantom hold violations on every path between them -- 87 of them,
at first. Three alternatives were tried and measured before this one:
`set_clock_latency` with a single value, the same with `-early`/`-late`, and
sourcing only the generated clock internally. The reasoning for each is
recorded in `constr/ultra_sd.sdc` next to the constraint itself.

### How much margin the SD pads actually have, and why it matters

The table above says closed, and that is true, but it understates how little
room there is on one specific family of paths. The SD outputs launch on
`sd_clk_core` and have to meet the card's tISU inside one SD period. Measured
on the sign-off run, the four register-to-pad paths come out at:

| path | slack |
|---|---|
| `u_cmd/u_engine/cmd_out_q` -> `u_phy/u_iobuf_cmd` | the tightest of the four |
| `u_line/dat_out_q[1]` -> its pad | +0.252 ns |
| `u_line/dat_out_q[2]` -> its pad | +0.405 ns |
| `u_line/dat_out_q[3]` -> its pad | +0.571 ns |

A quarter of a nanosecond is not margin, it is luck of placement. This was
measured the hard way: an unrelated nine-cell addition elsewhere in the core
moved a register far enough to put the CMD path at **-0.267 ns**, with nothing
on that path changed. The change was backed out, and the fact was written into
`doc/README.md`'s known limitations, because it is a property an integrator has
to know: **run `syn/pnr_timing.py` on every build rather than assuming closure
survives a change**, and expect the CMD pad to be the path that fails first.

Two tool-side levers were tried and neither is reachable through `gw_sh` in
this version -- `set_option -place_option 2 / -route_option 2` and
`set_option -oreg_in_iob 1` both produced byte-identical results, so unknown
option names are ignored silently. `doc/tx_launch_edge.md` section 6(c)
measures what IOB output registers would remove -- 1.06 ns, four times the
worst miss -- so the lever is real; it is the headless flow that cannot pull
it.

### What the +20% set does not scale

What the +20% set does **not** scale is the SD pad timing, and that is
deliberate. tISU and tODLY at the card's pins are the *card's* numbers from the
Physical Layer specification; scaling them to demand 20% more margin would be
asking the design to work with a card clocked 20% above 50 MHz, which R-DEG-3
treats as a hard ceiling. The pads are false-pathed in that set with the
reasoning written next to the exception.

## 10. Soak result (R-MEAS-5)

**Met.** 30.7 minutes of alternating write and verified read-back -- 185 000
pairs, 370 000 transfers -- with zero unrecovered errors and, as it happens,
zero recovered ones either. Retries counted in `STAT_RETRY` would have been
acceptable; there were none.

The soak runs from its own bitstream, `bench/impl/pnr/soak.fs`, built by
`bench/build_soak.tcl` with `BENCH_SUITE 4`: one 8-block write and one verified
read-back per iteration, with the mismatch count, the retry count and the
R-IF-11 counter cross-check reported at five checkpoints.

### The calibration ladder

| iterations | wall time | mismatches at the 5 checkpoints | retries | `ERR` | log |
|---|---|---|---|---|---|
| 20 | seconds | 0, 0, 0, 0, 0 | 0 | 0 | `reports/soak20.txt` |
| 100 | seconds | 0, 0, 0, 0, 0 | 0 | 0 | `reports/soak100.txt` |
| 140 000 | 1396 s = 23.3 min | 0, 0, 0, 0, 0 | 0 | 0 | calibration run, log overwritten by the final one |
| **185 000** | **1844 s = 30.7 min** | **0, 0, 0, 0, 0** | **0** | **0** | **`reports/soak_30min.txt`** |

The iteration count for the final run was measured up, not guessed. The clean
140 000-pair run took 1396 s, which is 9.97 ms per write-plus-verified-read
pair; 185 000 pairs is therefore 1844 s, and that is the run in the last row.
It is the one that closes R-MEAS-5: **370 000 transfers, 1.45 GiB moved in each
direction, zero mismatches, zero retries, zero error codes, zero UART framing
errors, and `FAILFROM = 0xFFFFFFFF`.** Note that the retry count being zero is
stronger than the requirement asks for -- R-MEAS-5 permits recovered retries,
and this run did not need any.

`SK_XCHK` -- the bench's own SD-cycle count of each read minus the core's
`STAT_DATA` for the same read -- came back between 299 387 and 299 571 across
the five checkpoints of the 185 000-pair run, between 299 429 and 299 742 on
the 140 000-pair run, and between 298 969 and 299 197 on the two short ones.
That is the R-IF-11 cross-check on hardware, holding to one part in a thousand
over 370 000 transfers: the core's payload counter and an independent count of
the same transfer agree on where the cycles went.

`FAILFROM` reads `0xFFFFFFFF` on every run, which is the sequencer's way of
saying it never entered its failure state.

### The defect in the harness that this turned up

Getting here was not a straight line, and the detour is worth recording
because it produced exactly the kind of evidence that gets mistaken for a
design bug.

A 500-iteration build produced no UART output at all. A 1000-iteration build
did the same. A 2000-iteration build ran, but reported a read-back mismatch --
reproducibly, 254 mismatched beats on two consecutive runs of the same
bitstream and 62 on a third, always confined to the last of the five checkpoint
intervals, always with zero CRC retries and zero error codes. A read-back that
disagrees while CRC16 accepted every block is a serious claim, and it would
have been the wrong one: the 1000-iteration bitstream was placed and routed
with **1068 setup-violated endpoints**. The report said so; nobody had read it.

The cause was in the benchmark, not the core. The checkpoint test was
`(iteration + 1) % (SOAK_ITERS / NDIV) == 0` -- a 32-bit modulo by a build-time
constant, which is a divider, in the sequencer, on a path that has to meet the
system clock. At 20 iterations it cost nothing, because 20/5 = 4 and a modulo
by a power of two is a mask; at 1000 it cost 350 logic cells and closure. A
measurement parameter had been quietly deciding whether the bitstream worked.

Two things changed as a result:

- `bench_core` now counts down to each checkpoint instead of taking a modulo.
  One comparison against zero, the same size at every iteration count, and
  `SOAK_ITERS` no longer has to divide exactly by `NDIV`.
- `syn/pnr_timing.py` reads a Gowin P&R report and exits non-zero on any
  violated endpoint. `gw_sh` exits 0 either way, so the gate has to be
  separate, and every bitstream now passes through it before it is programmed.
  Both bitstreams used for the numbers in this report pass it: 0 setup, 0 hold.

**None of the mismatch figures in this subsection are evidence about the
core**, and they are recorded only so that the next person to see a number like
them checks the timing report first.

## 11. Graceful degradation, Section 7.4 (R-DEG-7)

The procedure has three fallbacks, and they divide by what can be exercised
from the register map.

**Reduced SD clock: done, on hardware.** Section 6's characterisation sweep is
the measurement -- five frequencies from 49.5 MHz down to 399 kHz, each with a
verified read-back, in every one of the five tier runs. The divisor is a live
input to the clock controller, so slowing the bus down needs no
re-initialisation and no rebuild.

**1-bit and Default Speed: done, on hardware.** These two cannot be exercised the way the clock can, and the
reason is a sequencing requirement worth stating: `CFG_PHY.FORCE_1BIT` narrows
the **host** only -- `system_controller` computes `bus_wide_q` as
`bus_4bit_i & ~force_1bit_i`, while the card's width is whatever the
initialisation ladder's ACMD6 left it at. Setting the bit after initialisation
desynchronises the two and corrupts every transfer for a reason that has
nothing to do with degradation.

So the procedure is: write `CFG_PHY`, pulse `CTRL.SOFT_RESET`, wait for
`STATUS.CARD_READY` to **drop**, wait for it to rise again, and only then read
`STATUS`. The drop is not optional -- polling `CARD_READY` straight after the
reset reads the stale 1 from the previous initialisation and reports success
without having tested anything. `CFG_PHY` survives the soft reset, which is
what makes the sequence possible at all.

That is `bench_core` SUITE 5, built by `bench/build_deg.tcl` into its own
bitstream, and `test/integration/tb_bench_deg.sv` runs it in simulation so the
hardware attempt was not the sequence's first execution.

Simulation and hardware agree exactly. Both report `STATUS = 0x1c` after the
forced re-initialisation, and that value decodes against Table 5-1 as card
present, card ready, `speed_q = SPEED_DS`, `bus_wide_q = 0` -- **BUS_WIDTH =
1-bit, SPEED_MODE = Default Speed**. The verified pair that follows in that
mode mismatches no beat, spends no retry and reports no error.

| field | simulation (`T tb_bench_deg`) | hardware (`R deg_hw.txt`) |
|---|---|---|
| `SUITE` | 5 | 5 |
| `STATUS` after forced re-init | `0x1c` | `0x1c` (28) |
| `MISMATCH` | 0 | 0 |
| `RETRY` | 0 | 0 |
| `ERR_CODE` | 0 | 0 |
| `FRAM_ERR` | -- | 0 |
| `FAILFROM` | never set | `0xFFFFFFFF` |

What shows the re-initialisation really happened, rather than the poll reading
a stale `CARD_READY` from the first one, is the sequencer itself: `S_DG_WAIT`
only advances after `STATUS.CARD_READY` has been observed low and then high
again, and `FAILFROM` would name that state if the re-init timeout had expired
instead. The run reports `INIT_CYC = 436664` and `INIT_SD = 4198`, against
`541048` and `4200` on the soak bitstream -- the ladder takes very nearly the
same number of SD cycles, as it should, since the commands are the same ones;
the system-clock figure differs because the two bitstreams do not spend the
same time at the 400 kHz init divisor before the ladder's own clock change.

That is R-DEG-5 as well as R-DEG-7: the mode reported is the one actually
negotiated, not the one that was asked for.

The `CH_*` rows in `reports/deg_hw.txt` are the report engine's fixed field
list, not a sweep SUITE 5 runs; their zeros carry no meaning here. The
characterisation sweep belongs to SUITE 0 and is in section 6.

# Measurement logs

Generated artefacts -- committed, because every number in `doc/report.md` must
be traceable to a log here (R-DEL-5).

| File | Contents |
|------|----------|
| `gowin_resource.txt`   | post-P&R utilisation of the core, sign-off constraints |
| `gowin_timing.txt`     | timing report, sign-off (99 / 49.5 MHz) |
| `gowin_timing_margin20.txt` | timing report, +20% margin set (118.8 / 59.4 MHz) |
| `gowin_timing_bench.txt` | timing report of the bench harness bitstream |
| `tier_run1.txt` … `tier_run5.txt` | the five tier measurement runs (Section 12.3, R-MEAS-4) |
| `soak_30min.txt`       | 30-minute soak, 185 000 pairs (R-MEAS-5) |
| `soak20.txt`, `soak100.txt`, `soak2000*.txt`, `soak1000.txt`, `soak_cal500.txt` | the calibration ladder; `README_soak_artefacts.md` explains these, including the two empty ones |
| `deg_hw.txt`           | Section 7.4 degradation procedure, forced 1-bit + Default Speed (R-DEG-7) |
| `sim_throughput_read.txt`, `sim_throughput_write.txt`, `sim_counter_crosscheck.txt`, `sim_freq_sweep.txt` | the performance testbenches' own output |
| `bench_live_*.txt`     | development runs kept for the sweep analysis below |

## Reading the throughput fields

Two different numbers in the same log answer two different questions, and the
sweep is the one that gets misread.

| Field | What it is |
|---|---|
| `RD_Mbx10` / `WR_Mbx10` | steady-state throughput over the 131072-block (64 MB) run. These are the numbers to quote. |
| `CH_RDx10` / `CH_WRx10` | the time one 512-block (256 KB) transfer takes, expressed as a rate. Includes the fixed per-transfer cost. |

`CH_RDx10 = 1200` next to `RD_Mbx10 = 1831` is not a contradiction and not a
regression: both ran the same path at the same divisor. A transfer pays a fixed
cost once -- the command, the card's access latency, the closing CMD12 and the
programming drain that `ultra_sd_block`'s `S_BUSY` waits out -- and 512 blocks
is too few to amortise it.

The sweep separates the two parts on its own, because the fixed part does not
scale with the divisor and the payload part does. The increment between two
adjacent divisor points is the payload time of the faster one; whatever is left
of its total is the fixed cost. On `bench_live_final.txt`:

| | payload | fixed cost |
|---|---|---|
| read | 193.7 Mbit/s (96.8% of the 4-bit 50 MHz line rate) | 6.65 ms / transfer |
| write | at the line rate within the report's 0.1 Mbit/s granularity | 4.03 ms / transfer |

The increments double as the divisor doubles (10.83 then 21.63 ms, a ratio of
1.998), which is what makes the split trustworthy rather than a fit. Both
directions carry a fixed cost, so neither is inheriting the other's.

`RD1_TTF` belongs to the same family: 126238 cycles (1.26 ms) before the first
beat of a single-block read, against 133 cycles to drain the whole block once
data starts. The host pipeline runs at one word per cycle; the wait is the
card's read access on a block that was never written. `bench_core.sv` picks a
cold LBA for that measurement deliberately and documents the two neighbouring
cases it avoids.

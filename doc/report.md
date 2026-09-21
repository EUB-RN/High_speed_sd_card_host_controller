# Measurement report

Required by R-DEL-4. Every number here must be traceable to a delivered log
file in `reports/` (R-DEL-5). Numbers without logs are not accepted.

Produced by the Section 12.3 standard procedure, run with the supplied harness
unmodified (R-MEAS-1), on the reference card (Samsung EVO 32 GB).

## Declared tier

State plainly which tier is claimed, and the minimum-of-five figures that
support it. If one run touched a higher tier, say so.

## 1. Five-run read and write rates

Min / mean / max across five consecutive runs. The tier is awarded on the
**minimum**, with zero verifier mismatches in every run (R-MEAS-4).

| Run | read_rate (Mbit/s) | write_rate (Mbit/s) | verifier errors |
|-----|--------------------|---------------------|-----------------|

## 2. Efficiency (Section 12.4 formulas)

- `read_efficiency  = payload_bits / (elapsed_sd_cycles * 4)`
- `host_write_eff   = payload_bits / ((elapsed_sd_cycles - stat_busy_cycles) * 4)`
  -- must be >= 85% (R-PERF-5)

## 3. Mean block gap / latency L4

`mean_block_gap = stat_gap_cycles / (blocks - 1)` over a 64 MB multi-block
read (R-LAT-2).

## 4. Graded latencies, Table 11-1

| ID | Metric | Limit | Measured |
|----|--------|-------|----------|
| L1 | CTRL.START -> first CMD bit | <= 32 SD clocks | |
| L2 | last DAT bit -> last AXI-Stream beat | <= 16 SD clocks | |
| L4 | mean inter-block idle | <= 4 SD clocks | |
| L5 | command-to-command idle beyond Ncc | <= 8 SD clocks | |
| L7 | CRC error -> recovery command | <= 128 SD clocks | |

## 5. Report-only figures, Table 11-2 (R-LAT-3)

Initialisation time (ms, rst_n release -> STATUS.CARD_READY); random
single-block read latency p50/p99/max over >= 10,000 random LBAs; card-busy
distribution on write from STAT_BUSY.

## 6. Characterisation table (R-MEAS-6)

Measured read and write rate against SD clock frequency on the reference card
only, at divisors giving approximately 400 kHz, 6 MHz, 12 MHz, 25 MHz, 50 MHz.

## 7. Post-P&R utilisation against Table 9-1

## 8. Soak result (R-MEAS-5)

30 minutes alternating write and read-back, zero unrecovered errors. Retries
counted in STAT_RETRY are acceptable and expected.

## 9. Graceful-degradation result (Section 7.4)

Same bitstream, configuration changes only, on the supplied slow card.

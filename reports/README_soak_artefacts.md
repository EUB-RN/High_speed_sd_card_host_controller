# What the soak logs are, including the empty ones

`doc/report.md` section 10 tells this story; these are the files behind it.

| file | iterations | what it shows |
|---|---|---|
| `soak20.txt` | 20 | clean: 0 mismatches, 0 retries, `ERR` 0 at all five checkpoints |
| `soak100.txt` | 100 | clean, same |
| `soak_30min.txt` | 185 000 | the R-MEAS-5 run. Re-measured after the L2 decomposition described in `doc/checklist.md`, so it is a run of the delivered RTL |
| `soak1000.txt` | 1 000 | **empty on purpose.** This bitstream produced no UART output at all in three minutes of listening. It was placed and routed with 1068 setup-violated endpoints, because the checkpoint test was a 32-bit modulo by the iteration count and 1000/5 is not a power of two |
| `soak_cal500.txt` | 500 | **empty for the same reason**, found first and misdiagnosed as a hang in the sequencer |
| `soak2000.txt`, `soak2000_a.txt`, `soak2000_b.txt` | 2 000 | the same defective build when it *did* run: 62 mismatched beats on the first run and 254 on two consecutive repeats, always in the last checkpoint interval, with zero CRC retries and zero error codes. **These numbers are not evidence about the core.** They are what a timing-violating bitstream reports, and they are kept so that the next person to see a figure like them checks the timing report before believing it |

The empty files are deliberately not deleted. "No output" is the measurement
that identified the defect, and a missing file would read as a run that was
never done.

The fix is in two places: `bench_core` counts down to each checkpoint instead
of taking a modulo, and `syn/pnr_timing.py` exits non-zero on any violated
endpoint so that no bitstream reaches the board unchecked again.

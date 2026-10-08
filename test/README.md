# Verification

Required by R-DEL-6/R-DEL-7. Depth is up to the author, and its quality is one
of the larger factors in the optionals judgement (Table 14-3).

## Running

Everything runs through GNU make, from this directory. There is no vendor
simulator GUI in the loop and no script to source: `make` is the regression,
and the same command is what CI runs.

```bash
make                     # the regression: every category, in order
```

```bash
make unit                # one category
```

```bash
make clk_controller      # one test, wherever it lives
```

```bash
make list                # what exists, by category
```

```bash
make DUMP=1              # also write a .vcd
```

```bash
make lint                # the R-LANG-9 zero-warning lint gate
```

Each testbench is self-checking: it prints `PASSED` or `FAILED` with a check
count and exits non-zero on failure, so `make` works directly as a CI gate.
Build output goes to `build/<category>/`, which is git-ignored.

`SIM` selects the simulator. The default is Icarus Verilog; `SIM=verilator`
uses Verilator 5.x via `--binary --timing`. Verilator 4.x cannot run a timed
SystemVerilog testbench (the version installed here is 4.038, so `SIM=verilator`
will reject `--binary`), but it is still the right tool for `make lint`.

Randomised tests take `SEED=<n>`, and print the seed they used, so every
failure is replayable.

Icarus 11 rejects `localparam int unsigned`, so RTL that these testbenches
compile uses plain `int`. Anything still written as `int unsigned` needs the
same change before its testbench can run under Icarus.

## Layout

One directory per verification category. A category declares what it contains
in its own `tests.mk` -- the test names and, per test, its source list -- and
nothing else; the simulator flags and rule engine live once in `mk/common.mk`.
Adding a test means one line in a `tests.mk`.

```
test/
  Makefile              the entry point; includes every category
  mk/
    common.mk           simulator selection, the per-test rule engine
    lint.mk             the R-LANG-9 gate, one entry per synthesizable top
  common/               shared infrastructure: card model, VIP, covergroups,
                        checker macros  (see common/README.md)
  unit/                 one module against its own contract
  functional/           end-to-end scenarios against the card model
  integration/          adjacent RTL layers exercised together
  vip/                  bus interfaces against the AMBA specification
  error_injection/      hostile environment, plus R-DEL-7 RTL mutation
  formal/               SVA properties and proofs
  coverage/             functional coverage closure and the ratchet
  stress/               long, randomised, deliberately hostile
  performance/          throughput and the characterisation sweep
```

## The categories

Why these and not one flat pile: each answers a different question, fails for
a different reason, and runs at a different point in the cycle.

| Category | The question it answers | When it runs |
|---|---|---|
| `unit` | does this module meet its own contract, in isolation? | every commit |
| `functional` | does the core do what Section 6 says, end to end? | every commit |
| `vip` | are the bus interfaces legal AMBA, independent of our use of them? | every commit |
| `error_injection` | does it recover from a hostile card -- and does the testbench notice a broken design? | every commit (mutation: on demand) |
| `formal` | do the invariants hold for *all* inputs, not just the ones we drove? | on change to the proven block |
| `coverage` | which of the specification did the regression actually reach? | nightly, merged |
| `stress` | does it survive hours of randomised abuse? | nightly |
| `performance` | does it meet the number, not just the behaviour? | nightly, and before a release |

Two of these are the ones usually left out of a project this size, and both are
worth more than another directed test:

- **`vip`** -- protocol monitors that watch every beat on AXI4-Lite and
  AXI4-Stream and fail on the first violation. R-IF-1/2/5/6/7/8 are *protocol*
  requirements; a functional test that happens to pass does not demonstrate
  them. No vendor VIP is assumed here -- the monitors are ours, under
  `common/vip/`, so the delivery stays self-contained (R-IP-3).
- **`coverage`** -- a green regression with no coverage data only proves that
  whatever ran, passed. The covergroups say which Table 5-3 error codes were
  reached, which `CFG_CLK` divisors were exercised, which Table 7-1 fallbacks
  were entered.

`formal` carries its properties in bind files rather than in the RTL, because
Icarus does not support concurrent assertions and the synthesizable sources
have to stay clean. The same binds double as runtime checkers in the
simulation categories, which is where they pay off immediately even before any
proof is run.

## Coverage today

| Test | Category | Module | What it checks |
|---|---|---|---|
| `clk_controller` | `unit` | `clk_controller` | reset state, divisor mapping, rounding/clamping, duty cycle and glitch-free runtime divisor changes |
| `phy_clk_gate` | `unit` | `clk_controller` + `ultra_sd_phy_gowin` | clock gates, low parking, runt-pulse rejection and pad clock mux handoff |
| `crc7` | `unit` | `ultra_sd_crc7` | CMD0/CMD8 known-answer vectors and 100 random matrix/reference comparisons |
| `crc16` | `unit` | `ultra_sd_crc16` | CRC-16/XMODEM known-answer vector and 100 random matrix/reference comparisons |
| `ultra_sd_reg` | `unit` | `ultra_sd_reg` | reset values, RO/RW/W1S/W1C behaviour, byte strobes, request snapshot, IRQ collision and SLVERR |
| `async_fifo` | `unit` | `async_fifo` | asynchronous ordering, speculative commit/rewind, full/overflow and underflow |
| `ultra_sd_cmd` | `unit` | `ultra_sd_cmd` | exact CMD0 frame/CRC, bounded response timeout and retry event |
| `system_controller` | `unit` | `system_controller` | reset release, active-low debounce, ramp-edge count, transfer phases, lane locking and soft reset |
| `ultra_sd_line` | `functional` | `ultra_sd_line` | runtime 8-byte framing with a 512-byte-capable engine, 1/4-bit TX/RX, CRC corruption and write-status token errors |
| `init_ladder_basic` | `functional` | `ultra_sd_init` | CMD0..ACMD6 basic ladder, R7/OCR/RCA/CSD decoding and card removal |
| `init_ladder_full` | `functional` | `ultra_sd_init` | 176 checks over SCR, ACMD6, CMD6 status, 4-bit/HS success, 1-bit/DS fallback, CRC, DAT timeout, CMD8 mismatch, command errors and removal |
| `block_requests` | `functional` | `ultra_sd_block` | 59 checks: ranges, CMD17/18/24/25, ACMD23/CMD12/CMD13, CRC retry exhaustion, backpressure, tokens and timeouts |
| `block_flow` | `functional` | `ultra_sd_block` | payload forwarding, speculative commit/rewind, multi-block read/write and recovery sequences |
| `init_cmd_stack` | `integration` | init + command arbiter + command engine + CRC7 | serial CMD0..ACMD6 exchange against a behavioural card |
| `top_integration` | `integration` | complete `ultra_sd_top` + SD card model | real pads and AXI registers, 74-clock ramp, full SCR/ACMD6/CMD6 DAT path, 4-bit High Speed and decoded capacity |
| `block_stat` | `integration` | `ultra_sd_block` + `ultra_sd_stat` | DONE/ERR/IRQ propagation, SD-cycle counters and STAT_CLEAR |
| `block_axis_read` | `integration` | `ultra_sd_block` + async FIFO + AXI read master | 512-byte speculative block, CRC commit visibility, ordering and request-level tlast |
| `block_axis_write` | `integration` | AXI write slave + async FIFO + `ultra_sd_block` | full-block buffering, 128-beat ordering/tlast, block consumption, commit and drain |
| `vip_selftest` / `vip-cocotb` | `vip` | AXI/register/stream blocks | monitor calibration plus AXI4-Lite and AXI4-Stream protocol/backpressure tests |
| `sd_card_model` | `vip` | SD card behavioural VIP | pin-level init commands, 4-bit block read/write, CRC7/CRC16, storage backdoor and fault injection |

End-to-end top-level block transfers, broader fault injection, coverage,
stress and performance tests remain. Each category's `tests.mk` carries the
authoritative list.

`bench_flow` now gets through the complete SCR/ACMD6/CMD6 initialization and
the single-block write/read phase scan.  It deliberately remains a failing
regression at the multi-block preconditioning write: the second/next block is
cut short and the core reports `ERR_DAT_TIMEOUT`.  This is a real top-level DAT
write sequencing defect, not an expected timeout or a disabled assertion.

## Still required by R-DEL-6

- top-level single-block and multi-block read/write through AXI and SD pads
- CRC error injection and recovery -- `error_injection/`
- AXI4-Lite register access, including the SLVERR path -- `vip/`

R-DEL-7: the testbench must demonstrably **fail** when the design is broken.
The client injects the faults listed in Appendix E.4 into the RTL and re-runs
it; it must catch them. A behavioural card model that catches injected faults
is worth more, for the optionals pool, than everything else on that list
combined -- which is why the model lives in `common/models/` and not inside
one testbench.

Mutation-test each new testbench as it is written: change one thing in the RTL,
confirm the testbench fails, put it back. `error_injection/` is where that gets
automated against the Appendix E.4 list. Every wait must be bounded, so that a
broken design produces a failure rather than a hang.

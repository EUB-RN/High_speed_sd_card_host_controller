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
| `clk_controller` | `unit` | `clk_controller` | reset state; the startup guard; the divisor to ratio mapping across 400 kHz .. 50 MHz; even-rounding and clamping; duty cycle; edge-strobe alignment; glitch-free adoption of a new `CFG_CLK`; gating in both `CLK_GATING_EN` builds |

Everything else is still to be written. Each category's `tests.mk` carries its
own list of what is missing, which is the authoritative version of the
summary below.

## Still required by R-DEL-6

- the initialisation ladder (Section 6.1 / Appendix B) -- `functional/`
- single-block and multi-block read -- `functional/`
- single-block and multi-block write -- `functional/`
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

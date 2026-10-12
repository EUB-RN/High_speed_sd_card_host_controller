# Formal

Property proofs, and the one piece of third-party code in the verification
tree.

## What is here

| File | What it is |
|---|---|
| `third_party/faxil_slave.v` | ZipCPU's AXI4-Lite property set, Gisselquist Technology, **Apache-2.0**. Origin and licence are in the file's own header (R-IP-3). Taken unmodified. |
| `faxil_axi4_lite_slave.sv` | our wrapper: `axi4_lite_slave` next to the property set, register-file side left free so the solver can answer with anything |
| `axi4_lite_slave.sby` | the SymbiYosys driver, `bmc` and `prove` tasks |
| `fasync_fifo.sv` | property set for the commit/rewind FIFO: gray round-trip, capacity, no read-from-empty, bounded uncommitted region, exact rewind, no withdrawal of a published word, soft clear. **Bounded proof passes (`bmc`); induction does not close -- see below.** |
| `async_fifo.sby` | its driver, `bmc` and `prove`, DEPTH 4 so the pointers wrap inside the bound |

## Why a proof as well as the VIP

`test/vip/` can only report the violations its stimulus provoked. A proof
reports that no stimulus can provoke one -- including the handshake deadlocks
that random traffic reaches only by luck, which is what the `F_AXI_MAXWAIT` and
`F_AXI_MAXDELAY` liveness bounds in the wrapper are for.

It is also an independent reading of the same specification our own
`common/vip/axi4_lite_monitor.sv` encodes, written by someone else. Where the
two agree, the monitor is corroborated; where they disagree, one of them is
wrong and it is worth finding out which.

## Running

```bash
sby -f test/formal/axi4_lite_slave.sby
```

**SymbiYosys is not installed in this checkout.** `yosys` is present but `sby`
is not, so the proof above cannot be run here yet. It comes with the OSS CAD
Suite, or from source:

```bash
pip install git+https://github.com/YosysHQ/sby.git
```

A solver backend is also needed -- `yices` or `z3` -- which the OSS CAD Suite
bundles.

## Still to write

- `bind_async_fifo` -- pointer invariants, no overflow or underflow
- `bind_clk_controller` -- gating and duty-cycle properties
- `cdc_assertions` -- one property per crossing listed in `doc/cdc.md`
- the AXI4-Stream property set (`faxis_slave.v` from the same project) against
  `axis_rd_master` and `axis_wr_slave`


## The FIFO proof, and exactly where it stands

`make formal-fifo` runs it. **The bounded proof passes.** `sby`'s `bmc` task
returns `PASS` over 24 steps at `DEPTH = 4`, which is a depth at which the
pointers wrap, and the `prove` task's basecase passes too. Induction does not
close, so the honest statement is: every property holds for all behaviours up
to 24 cycles, and is not yet proved for all time.

It is still not in the default `formal` target, for one reason only -- the
`prove` task returns UNKNOWN, and a default target that is not green teaches
people to ignore the target. Run `make formal-fifo` to get the bounded result.

### What was actually wrong, and it was not the design

Everything below used to fail: five state assertions, all in the first cycle
the guard let them be checked. The cause was mundane and total. The property
file read the DUT's pointers as `u_fifo.wptr_bin` and friends -- legal
SystemVerilog, and silently useless here, because Yosys's Verilog front end
does not resolve a hierarchical reference into the child's driver. It creates
an undriven wire of that name. The log said so on every run:

    Warning: Wire fasync_fifo.\u_fifo.wptr_bin is used but has no driver.

So every property comparing a pointer against anything was comparing against
nothing, and failed. Nobody had read the warnings, and the failures were being
diagnosed as an initial-state problem, which they were not.

The fix is that `async_fifo.sv` exports the pointers under `` `ifdef FORMAL ``
and the wrapper connects them as ports. `FORMAL` is defined only by
`async_fifo.sby`, so the delivered design is unchanged -- verified by lint and
by `tb_async_fifo` -- and the proof now reads real values.

### The three things that were wrong in the properties

1. **"A commit advances the published pointer by at most one."** It does not:
   `wr_commit` assigns `wptr_pub <= wptr_nxt`, so one commit publishes the
   whole speculative region, up to DEPTH words. The property was wrong, not
   the design. It is now stated as an equality against the speculative
   pointer, which is both correct and stronger.
2. **The two soft clears were independent free inputs.** They are one event
   seen from two clock domains (`sd_soft_clr` and `axi_soft_clr`), and this
   task runs `multiclock off`, so letting them differ modelled something the
   synchronisers prevent. Now assumed equal, with the uncovered window
   documented in the file.
3. **A soft clear was allowed to be one cycle wide.** The design holds it for
   at least `SOFT_RST_CYC = 16` clk cycles *and* until every domain
   acknowledges, which is what keeps the read pointers pinned at zero while
   the stale gray value drains. Now assumed, because the design guarantees it.

### The design finding worth keeping

The proof found a real sharp edge, and it is worth stating because it is the
kind of thing only a solver finds. A soft clear zeroes each side's pointers
but deliberately does **not** clear the cross-domain synchroniser chain --
`async_fifo.sv` explains why next to the code. So if a clear were only a cycle
or two wide, the read side would briefly decode a *stale, larger* writer
pointer, prefetch a word the clear was supposed to discard, and leave its read
pointer permanently ahead of the writer's, with `rd_level` underflowed to look
empty while a word is swallowed.

The delivered design is safe from this, by the 16-cycle-plus-acknowledge hold
above and by `ultra_sd_block` returning to S_IDLE on `soft_clr` so nothing
reads those outputs. It is a trap for anyone reusing this FIFO somewhere that
clears mid-stream. `doc/report.md` records it as well.

### What is left

Induction fails on the capacity bounds and on the synchroniser-chain
invariants added to support them -- `fasync_fifo.sv` properties 2 and 2a. The
missing piece is a complete inductive invariant: induction starts from any
state satisfying the assertions, and the set as written still admits a start
state with a gray value in flight that no real execution produces. Closing it
means strengthening 2a until the set is closed under one step. The invariants
already there -- every chain stage within DEPTH of the pointer chasing it --
are the right shape and not yet sufficient.

Alongside the bounded proof, `tb_async_fifo` (65 checks) and `mutation.sh`
(which catches a broken commit, a broken rewind and an over-published pointer)
are what stand behind the FIFO.

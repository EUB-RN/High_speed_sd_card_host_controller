# Formal

Property proofs, and the one piece of third-party code in the verification
tree.

## What is here

| File | What it is |
|---|---|
| `third_party/faxil_slave.v` | ZipCPU's AXI4-Lite property set, Gisselquist Technology, **Apache-2.0**. Origin and licence are in the file's own header (R-IP-3). Taken unmodified. |
| `faxil_axi4_lite_slave.sv` | our wrapper: `axi4_lite_slave` next to the property set, register-file side left free so the solver can answer with anything |
| `axi4_lite_slave.sby` | the SymbiYosys driver, `bmc` and `prove` tasks |

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

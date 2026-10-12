# Submission checklist (Appendix C)

The first thing the client reads. A checklist that claims something the logs
contradict is worse than an honest gap, so every row below is either ticked
with the evidence that supports it or left open with the measurement that
shows why.

Evidence shorthand: `R` = `reports/`, `T` = the testbench named,
`P&R` = `syn/core_pnr/impl/pnr/`.

| ✓ | Item | Requirement | Evidence |
|---|------|-------------|----------|
| ☑ | Five-layer module hierarchy as in Figure 4-1 | R-ARCH-1 | `rtl/ultra_sd_top.sv` instantiates `u_axi`, `u_block`, `u_cmd`, `u_line`, `u_phy` and contains no logic of its own |
| ☑ | All Gowin primitives confined to ultra_sd_phy_gowin.sv | R-ARCH-2 | `grep` for `IOBUF`/`DQCE` finds them in that file only; every other top lints with `ULTRA_SD_NO_VENDOR_PRIM` undefined |
| ☐ | No module over 400 lines, no procedural block over 120 | R-ARCH-3, R-ARCH-4 | **partly met.** Was three modules and two blocks over the limits; now two modules and one block, and every one of them is in a layer this delivery may not restructure (L4, L1) or one where decomposition was measured and shown not to help (L3). `ultra_sd_cmd` was brought from 430 to 387 and its 179-line FSM to three blocks of 67/106/16, by splitting out `ultra_sd_cmd_tx`. Still over: `ultra_sd_block` 536 (L3 -- decomposition measured and shown not to help, see the note below), `ultra_sd_top` 427 (L4) and `ultra_sd_line.sv:233` at 182 (L1). See the note below |
| ☑ | Zero PLL instances in the core | R-CLK-5, R-RES-5 | `P&R` resource report: rPLL 0. The SD clock is `clk`/2 from `clk_controller` + DQCE |
| ☑ | SD clock runtime-adjustable, no hard-coded frequency | R-CLK-2, R-DEG-1 | `CFG_CLK` is a live input to the divider; `T tb_freq_sweep` sweeps it and `R sim_freq_sweep.txt` shows the time scaling with it. Hardware sweep: `R tier_run*.txt` `CH_DIV` rows |
| ☑ | Timing report shows positive slack at 50 MHz | R-CLK-6 | 0 setup / 0 hold violated endpoints on `constr/ultra_sd.sdc` **and** on `constr/ultra_sd_margin20.sdc`, which is the same design closed at 118.8 MHz |
| ☑ | AXI4-Lite: all five channels, SLVERR on unmapped access | R-IF-1, R-IF-2 | cocotb `test_axil_protocol.py`, 12/12; SymbiYosys `prove` against ZipCPU's property set closes by induction |
| ☑ | Register map exactly as Table 5-1 | R-IF-2 | `rtl/ultra_sd_pkg.sv` offsets `0x00`..`0x3C`, one register per row; `T tb_ultra_sd_reg`, and the map is reproduced in `doc/README.md` section 3 |
| ☑ | Both AXI4-Stream interfaces compliant, tlast correct | R-IF-5, R-IF-6 | cocotb `test_axis_protocol.py`; `T tb_block_axis_read` / `tb_block_axis_write` |
| ☑ | Survives arbitrary backpressure and producer starvation | R-IF-7, R-IF-8 | `T tb_random_traffic`, 604 checks with up to 90% random backpressure on both directions |
| ☑ | All five statistics counters, counting SD clocks, saturating | R-IF-11 | `T tb_counter_crosscheck`, 104 checks: each counter against an independent count of the same event, with both `STAT_RETRY` halves forced non-zero by injection. One measured caveat on `STAT_BUSY` is recorded in that file |
| ☑ | Error codes exactly as Table 5-3 | R-IF-12 | `T tb_coverage` error-code coverage section; `T tb_error_inject` reaches them by injection |
| ☑ | Init ladder in hardware, 74-clock ramp included | R-FUNC-1, R-FUNC-2 | `T tb_init_ladder_basic` / `tb_init_ladder_full`; on the board `INIT_ms` = 5-6 ms with 4271-4569 SD cycles of command traffic |
| ☑ | CMD6 High Speed switch verified by status block read-back | R-FUNC-3 | `T tb_init_ladder_full`: the ladder reads the 64-byte switch status over DAT and commits High Speed only if the read-back agrees |
| ☑ | SDSC detected and rejected, not silently mishandled | R-FUNC-5 | `ultra_sd_init` fails a card with OCR.CCS = 0 as `ERR_UNSUPPORTED`; `T tb_init_ladder_basic` drives exactly that case |
| ☑ | 4-bit operation working | R-FUNC-6 | every board run reports 4-bit; `T tb_line_card` covers 1-bit and 4-bit framing |
| ☑ | CMD18/CMD25 multi-block streaming, ACMD23 used | R-FUNC-8, R-FUNC-11 | `T tb_throughput_read` / `tb_throughput_write` attribute every cycle of one CMD18 and one CMD25; the write's `S_PRE_ERASE` occupancy is the ACMD23 |
| ☑ | CRC16 checked on the fly, four lanes | R-FUNC-9 | `T tb_crc16`, 102 checks; `T tb_throughput_read` measures CRC16 at exactly its 16 spec cycles per block, so it is not a post-pass over a buffer |
| ☑ | Write CRC status token checked | R-FUNC-13 | `T tb_error_inject` write-NAK scenario: a bad status token provokes the block retry |
| ☑ | Card detect treated as active low | R-FUNC-14 | `sd_cd` = 0 means present throughout; `T tb_system_controller` card-detect cases |
| ☑ | Error recovery without full re-initialisation | R-FUNC-16 | `T tb_error_inject`, 141 checks over 4 scenarios: CRC16 retry, command retry, write NAK and stuck busy all recover with CMD12 + CMD13 and no re-init |
| ☑ | Every wait bounded by a named timeout | R-FUNC-17 | `NAC_TIMEOUT_CLK`, `PROG_TIMEOUT_CLK`, `NCR_TIMEOUT_CLK`, `ACMD41_TIMEOUT_CLK`, `DAT_TIMEOUT_CLK`; the stuck-busy scenario in `T tb_error_inject` fires one and reports it |
| ☑ | All Table 7-1 fallbacks implemented and truthfully reported | R-DEG-5 | `T tb_coverage` drives `FORCE_1BIT` and `FORCE_DS` and checks `STATUS` reports the mode actually negotiated, not the one asked for |
| ☑ | Degradation procedure of Section 7.4 passed, same bitstream | R-DEG-7 | **met, on hardware.** Reduced clock: five frequencies from 49.5 MHz to 399 kHz, `R tier_run*.txt` `CH_*` rows. 1-bit and Default Speed: `bench_core` SUITE 5 from `bench/build_deg.tcl`, run on the board -- `R deg_hw.txt` reports `SUITE = 5`, `STATUS = 0x1c` after the forced re-init (present, ready, BUS_WIDTH 1-bit, SPEED_MODE Default Speed) and `MISMATCH`/`RETRY`/`ERR_CODE`/`FRAM_ERR` all 0, matching `T tb_bench_deg` (11 checks) exactly. Sequence and the stale-`CARD_READY` trap in `doc/report.md` §11 |
| ☑ | Verilator lint: zero warnings | R-LANG-9 | `make -C test lint`, every synthesizable top including the full hierarchy, `-Wall`, no output |
| ☑ | Within all hard resource limits, report attached | R-RES-1, R-RES-2 | `P&R`: 2472 logic (2372 LUT, 100 ALU), 1325 registers, 2/46 BSRAM, 0 rPLL, 0 latches -- 28 cells under the 2500 of Table 9-1 |
| ☑ | Five clean runs, minimum reported, zero verifier mismatches | R-MEAS-4 | `R tier_run1..5.txt`: read 183.0-183.1 Mbit/s, write 154.1-155.7, 0 mismatches and 0 retries on all five |
| ☑ | 30-minute soak, zero unrecovered errors | R-MEAS-5 | **met.** `R soak_30min.txt`: 185 000 write + verified-read pairs, 370 000 transfers, 1844 s = 30.7 min on hardware. 0 mismatches and 0 retries at all five checkpoints, `ERR_CODE` 0, `FRAM_ERR` 0, `FAILFROM = 0xFFFFFFFF`. Zero *recovered* errors too, which the requirement does not demand. Iteration count measured up the calibration ladder in `doc/report.md` §10 |
| ☑ | Characterisation table across frequency, reference card | R-MEAS-6 | `R tier_run*.txt` `CH_*` rows, five points from 49.5 MHz to 399 kHz; reproduced in `doc/report.md` section 6 |
| ☑ | README, cdc.md and report.md complete | R-DEL-1 … R-DEL-5 | `doc/README.md` (build, integrate, map, diagram, parameters, phases, limits, references), `doc/cdc.md`, `doc/report.md`. Every number in the report names its log |
| ☑ | Testbench covers the required scenarios | R-DEL-6 | 29 testbenches and 12 cocotb VIP tests green across unit, functional, integration, VIP, error injection, coverage, stress, formal and performance. Formal: ZipCPU's AXI4-Lite set proves against `axi4_lite_slave`; the commit/rewind FIFO set passes bounded model checking to 24 steps and does not close by induction (`make formal-fifo`, state in `test/formal/README.md`). The FIFO proof found a real constraint on soft-clear width -- `doc/report.md` §7b |
| ☑ | Testbench catches the Appendix E.4 injected faults | R-DEL-7 | `test/error_injection/mutation.sh`: **9 faults injected, 9 caught, 0 missed.** Each fault is applied to a copy of `rtl/`, the named tests are run against the copy, and a fault no test fails on is reported as a hole. One early fault turned out to be an equivalent mutant rather than a missed one; the script records why, because that is the trap it is most likely to fall into |
| ☑ | References cited in the README | R-IP-2 | `doc/README.md` section 8, with the one third-party file (ZipCPU's AXI4-Lite property set, Apache-2.0) listed separately under R-IP-3 |

**Declared tier: Tier 3.** Awarded on the slowest of the five runs: read
**183.1 Mbit/s** against the 170 Mbit/s threshold, write **154.0 Mbit/s**
against the 80 Mbit/s target, host write efficiency **96.4%** against the 85%
of R-PERF-5, and zero verifier mismatches in every run. `doc/report.md`
sections 1 and 2.

## The two graded latencies that are not met

Table 11-1's L2 (last DAT bit to last stream beat, 16 SD clocks) measures 65,
and L4 (mean inter-block idle, 4 SD clocks) measures 80.6 on the reference
card. Neither is a slow path: L2 is one block's drain time, because a block is
published to the host only after its CRC16 verifies, and L4 is the card
spacing its own blocks -- the host's share of it is 1 cycle. Both are measured,
attributed and argued in `doc/report.md` section 4 rather than left as a
number.

## The R-ARCH-3 / R-ARCH-4 size limits

R-ARCH-3 is 400 lines of RTL excluding comments and blank lines; R-ARCH-4 is
120 lines per `always_ff`/`always_comb`. Both are measured by the script
quoted at the end of this section, so the numbers here are reproducible rather
than asserted.

The brief for this delivery permits architecture changes at **L3 and L2 only**.
That bounds what could be done, and it is worth being explicit that the bound
is what leaves this row unticked: of the four remaining violations, three are
in L4, L1 and the one L3 module where decomposition was measured and rejected.

### What was fixed: L2

`ultra_sd_cmd` was 430 lines with a 179-line FSM. Both limits are now met:

| | before | after |
|---|---|---|
| `ultra_sd_cmd` module | 430 | **387** |
| its longest procedural block | 179 | **106** |
| its FSM, as three blocks | 179 | 67 + 106 + 16 |
| `ultra_sd_cmd_tx` module (new) | -- | 80 |
| `ultra_sd_cmd_tx` longest block | -- | 58 |

Two changes. The CMD serialiser -- the negedge shift register that puts the
48-bit frame on the pad and splices CRC7 into it -- moved to
`rtl/ultra_sd_cmd_tx.sv` behind a ten-signal interface. And the FSM was split
by **register group**, not by state: sequencing (`state_q`, `gap_next_q`,
`timer_cnt_q`), datapath (the latched request, the frame, the reported result)
and the `STAT_RETRY` counter. Splitting by group keeps every arm's condition
character-identical to what it was, which is what makes it a reorganisation
rather than a redesign.

That claim is tested, not asserted: the full regression (29 testbenches and 12
cocotb VIP tests, ~3400 checks) passes unchanged, the mutation harness still
catches 9 of 9 injected faults, and the tier suite on hardware reads 183.1 MB/s
against 183.0 before, with identical 924/964 per-mille efficiencies.

**The LUT budget decided the shape of the split.** A first attempt used four
blocks -- sequencing, framing, reporting, statistics -- which is tidier to read
and measured **2503 logic cells against the 2500 of R-RES-1**. Each block that
decodes `state_q` builds its own ten-way decode and the placer does not share
them. Merging framing and reporting into one 106-line block, and leaving the
statistics counter to test a single state rather than decode all ten, came
back at **2472** with 0 setup and 0 hold violations on both constraint sets.
The serialiser extraction on its own was 2470, so it is free; the FSM split
costs 2 cells in this shape and 33 in the other.

### What was measured and rejected: L3

`ultra_sd_block` is 536 lines and L3, so restructuring it is permitted. It was
not done, because extraction cannot get it under 400 and the arithmetic says so
before any code is written:

| | lines |
|---|---|
| ports and parameters | 65 |
| local declarations | 68 |
| logic | 403 |
| **total** | **536** |

The largest coherent group of logic that can leave is the line/arm control, the
timeout counter, the FIFO control and the statistics and status outputs --
sections 4, 5, 7 and 8 of the module, **172 lines**. But L3 sits between L4 and
three things below it, and a child needs those interfaces passed through:
14 line-interface ports, 17 FIFO ports, 5 status, 3 statistics, 3 clock and
reset, about 15 state and flag signals in, and about 11 results back. That is
roughly **70 lines of instance wiring in the parent**, against perhaps 20
declarations that stop being needed. 536 - 172 + 70 - 20 is about **414**:
still over, and now with a 68-wire seam through the middle of the module that
R-ARCH-3's actual purpose -- reviewability -- would be worse for, not better.

The module is already organised as eight independent `always` blocks with a
numbered comment per responsibility, and its longest block is 92 lines, so it
meets R-ARCH-4. Getting it under 400 means removing logic or rebuilding the
sequencer, with 28 cells of LUT headroom and a design that is otherwise closed
and hardware-validated. That trade was not taken.

### What is out of this delivery's scope

- `ultra_sd_top` at 427 is L4. It is wiring only -- R-ARCH-1 forbids logic in
  it -- so its length *is* its port list, and shortening it means adding a
  hierarchy level Figure 4-1 does not have.
- `ultra_sd_line.sv:233` at 182 lines is L1's main FSM, a single `case` over
  its state, so the length is the number of states times the arm. Splitting it
  by register group is exactly what worked for L2 and would very likely work
  here too -- it is left undone because L1 is outside the layers where this
  delivery may change architecture, not because it is hard.

### Reproducing the numbers

```bash
python3 - <<'EOF'
import glob, re
for f in sorted(glob.glob('rtl/**/*.sv', recursive=True)):
    L = open(f).read().split('\n')
    code = lambda xs: len([x for x in xs if x.strip()
                           and not x.strip().startswith('//')])
    if code(L) > 400:
        print(f'MODULE OVER 400: {f}  {code(L)}')
    i = 0
    while i < len(L):
        if re.search(r'\balways_(ff|comb)\b', L[i]):
            d = 0; j = i; started = False
            while j < len(L):
                for t in re.findall(r'\b(begin|end|case|endcase)\b',
                                    L[j].split('//')[0]):
                    if t in ('begin', 'case'): d += 1; started = True
                    elif t in ('end', 'endcase'): d -= 1
                if started and d <= 0: break
                j += 1
            if code(L[i:j+1]) > 120:
                print(f'BLOCK OVER 120: {f}:{i+1}  {code(L[i:j+1])}')
            i = j + 1
        else:
            i += 1
EOF
```

It prints three lines today: `ultra_sd_block` 536, `ultra_sd_top` 427, and
`ultra_sd_line.sv:233` 182.

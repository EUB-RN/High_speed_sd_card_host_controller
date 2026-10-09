# Clock-domain crossings

Required by R-DEL-2. List **every** crossing with its structure and its
justification, or state explicitly that the design is single-domain (R-CLK-3).

Permitted structures (R-CLK-3):

- two-flop synchroniser -- single-bit control only
- asynchronous FIFO -- data
- full handshake -- data

Undocumented crossings are a gate failure.

| # | Signal / bus | From | To | Structure | Justification |
|---|--------------|------|----|-----------|---------------|
| 1 | Read payload words (`DATA_W`) | `sd_clk` | `axi_clk` | Asynchronous FIFO (`rtl/axi4/async_fifo.sv`), instantiated in `axis_rd_master` | Payload is a data stream, so a FIFO rather than a handshake: it also absorbs host backpressure without stalling the card mid-block (R-IF-7). |
| 2 | Write payload words + `tlast` (`DATA_W+1`) | `axi_clk` | `sd_clk` | Asynchronous FIFO, instantiated in `axis_wr_slave` | Same reasoning in the other direction. `sd_block_ready` lets the block layer refuse to start a block that a stalled producer could not finish (R-IF-8). |
| 3 | FIFO write pointer (gray) | `wr_clk` | `rd_clk` | Two-flop synchroniser on a gray-coded pointer, then one pipeline stage on the gray-to-binary result | Only one bit changes per increment, so a sample taken mid-transition reads either the old or the new value, never a corrupt count. The extra stage after the conversion is for timing, not for metastability: the XOR tree fed the full/empty comparison and was the longest path in the design. A one-cycle-old pointer is pessimistic — the FIFO reports empty for a cycle longer, never shorter. |
| 4 | FIFO read pointer (gray) | `rd_clk` | `wr_clk` | As row 3, in the opposite direction | As above; one cycle of staleness makes the FIFO report full early rather than late. The pointer published here is the **committed** one (see "Speculation" below), which is what keeps a producer from overwriting data the consumer has not released. |
| 5 | `sd_cd` card-detect pad | asynchronous (mechanical) | `clk` | Two-flop synchroniser followed by a counter debounce, both in `system_controller` | The pad is both unclocked and mechanically bouncy. The synchroniser answers metastability, the counter answers contact bounce; they are separate problems, and a synchroniser alone would emit one `CARD_CHANGE` per bounce (R-IF-10). |
| 6 | `bus_wide` to the DAT engine | `clk` | `sd_clk_core` | Two-flop synchroniser (`wide_sync_q`) inside `ultra_sd_line` | Single-bit control, so a synchroniser is permitted. `bus_wide` is one bit by construction -- only two bus widths exist, so there is no multi-bit mask to sample across a change. The synchroniser output is latched into `wide_q` at transfer start and `system_controller` holds the input constant for the rest of the transfer. This row used to describe a synchroniser the RTL did not have: `bus_wide_i` was sampled straight into `wide_q`. (`dir` and `start` reach the same module from `ultra_sd_block`, which now runs on **this same clock**, so they are not crossings at all. They still pass through two pipeline stages, which cost the arming latency the block layer is built around -- a deliberate pipeline, not a synchroniser.) |
| 7 | `xfer_go` — transfer permission | `clk` | `sd_clk_core` | Two-flop synchroniser then edge detection, inside `ultra_sd_block` | Single-bit control. It is a **level** for the whole transfer rather than a pulse, because `CTRL.START` is one `clk` cycle wide and `sd_clk_core` is slower by the whole `CFG_CLK` range (divisor 2..255): a pulse would be missed entirely. The rising edge starts the transfer, the falling edge releases it (abort, card removal, or our own completion), so one wire carries both and the two can never disagree. |
| 8 | `card_present` | `clk` | `sd_clk_core` | Two-flop synchroniser inside `ultra_sd_block` | Single-bit, already debounced in `system_controller` (row 5). Used to tell a host abort from a card removal, so it only has to be right by the time the transfer unwinds. |
| 9 | `CTRL.STAT_CLEAR` | `clk` | `sd_clk_core` | Toggle in `system_controller`, two-flop synchroniser and change detection in **each** counter owner (`ultra_sd_line`, `ultra_sd_block`, `ultra_sd_cmd`) | Same pulse-width problem as row 7, but a counter clear has no phase to ride on. A toggle is width-independent: the producer flips a bit, the consumer acts on the change, and neither needs to know the divisor. Stretching a level instead would require knowing it. There are three consumers rather than one because the Table 5-2 counters live in the FSMs that produce their events (see below), so the one broadcast bit is the price of not re-creating those FSMs' clock domains somewhere else. |
| 10 | Table 5-2 counter values -- `STAT_DATA`, `STAT_BUSY`, `STAT_GAP` (28 bits each), `STAT_RETRY` halves (12 bits each) | `sd_clk_core` | `clk` | None: synchronous path closed by STA | `sd_clk_core` is a `create_generated_clock` off `clk` (`constr/ultra_sd.sdc`), so source and destination edges have a static relationship -- this is a divided-clock synchronous path, not an asynchronous crossing, and no structure from the permitted list applies or is needed. The register file samples it on an AXI read; each counter advances at most once per SD clock edge, so STA sees an ordinary multi-cycle path. This was two rows while the core had two gated clocks. |
| 11 | `rca`, `CARD_BLK`, `CFG_CLK_HW` from the init ladder | `sd_clk_core` | `clk` | As row 10 | Same class of path, and quasi-static on top of it: the ladder writes each of these once and never again while a card stays in the slot. |

`sd_clk_core` is a generated clock, not a crossing. Everything that makes it
lives in `ultra_sd_phy_gowin`, so no divided clock crosses a module boundary in
the fabric:

- **Division** happens in `clk_controller`, instantiated inside the PHY: a
  counter and a toggle flop produce a free-running 50 % duty clock from the
  divisor. `system_controller` supplies only the divisor and the gate enable;
  it produces no clock of its own.
- **Gating** happens in the same module, with one vendor `DQCE`. Nothing in
  the fabric sits on a clock path -- divider flop -> `DQCE` -> pad and core.
  Doing the gate in logic would route a generated clock through a LUT before it
  reaches the global clock tree, which makes glitch and runt freedom a
  synthesis outcome rather than a property of the design.

There is **one** divided clock, and L1, L2 and L3 all run on it. There used to
be two, `cmd_clk` and `line_clk`, with a `DCS` choosing which one drove the
`sd_clk` pad. That was dead logic and this document described its behaviour as
if it happened: both channels came from one divider at one divisor, the select
bit was tied to 0 in `ultra_sd_top`, and the two enables were the same wire.
The cost was not only on paper -- one waveform occupied two global clock
networks, and STA saw two base clocks, so every L1 <-> L3 path was analysed as
an inter-clock path. With one clock those paths are ordinary same-clock paths.
The card has a single clock pin, so two channels could never have carried
different waveforms in the first place.

Because the divider free-runs, gating does not disturb its phase: `DQCE` only
opens and closes the clock network, so a re-enabled clock continues on its own
period boundary.

## Table 5-2 counters

There is no statistics module. Each counter sits inside the FSM that produces
its event, clocked by that FSM's clock, so the unit is the SD clock cycle
(R-IF-11):

| Counter | Event | Module | Clock |
|---------|-------|--------|-------|
| `STAT_DATA` | `CELL_TX_DATA` / `CELL_RX_DATA` | `ultra_sd_line` | `sd_clk_core` |
| `STAT_BUSY` | `CELL_IDLE` with DAT0 held low | `ultra_sd_line` | `sd_clk_core` |
| `STAT_GAP` | `gap_active` in the streaming steps | `ultra_sd_block` | `sd_clk_core` |
| `STAT_RETRY[15:0]` | `retry_crc` | `ultra_sd_block` | `sd_clk_core` |
| `STAT_RETRY[31:16]` | `C_RETRY` step | `ultra_sd_cmd` | `sd_clk_core` |

Putting a counter anywhere else would mean exporting the raw event as a port
and re-deriving, in a second clock domain, a condition the owning FSM already
decodes. It would also break the retry counters specifically: those events are
one SD-clock cycle wide, so a counter on the faster `clk` would need edge
detection and would count one pulse several times if it got that wrong. Counted
at the source, a pulse is exactly one cycle and no edge detection exists.

The widths are in `ultra_sd_pkg` (`STAT_DUR_W` = 28, `STAT_RTY_W` = 12) so the
three modules cannot drift apart. The binding case for the duration counters is
the **fastest** SD clock, 50 MHz High Speed: 2^28 cycles = 5.37 s, against a
longest single measurement of 500 ms (the programming timeout). All of them
saturate rather than wrap, so a value read back always means "at least this
many".

`system_controller` counts the 74-clock ramp (R-FUNC-2) on the **gated** clock
coming back from the PHY (`sd_clk_i`), not on the divider output, so clocks
that never reach the pad are never counted. That signal is derived from `clk`
through the clock primitives and the global clock tree: same domain, skewed by
the tree's insertion delay, therefore a `.sdc` generated-clock definition and
not a crossing. The PHY's own sampling window is opened from a fabric twin of
the pad clock for the same reason -- see the module header.

The clock ratio between the two domains is not fixed: `CFG_CLK` changes the SD
clock at runtime (R-DEG-1), from below 400 kHz during initialisation to 50 MHz
in High Speed. No crossing may assume a ratio, which is why every one of them
above is either a gray pointer or the FIFO built on them.

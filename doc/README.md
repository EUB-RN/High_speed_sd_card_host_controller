# ultra_sd -- documentation

Required by R-DEL-1. This document must cover:

- **Build and program**: how to run the supplied command-line Gowin flow and
  load the bitstream onto the Tang Primer 20K + Dock.
- **Integration**: how to instantiate `ultra_sd_top` in another design, what the
  harness connects to, and what a user must provide.
- **Register map as implemented**: the map of Table 5-1, plus any registers
  added above `0x3C` (adding there is permitted; renaming, removing, resizing,
  redirecting or relocating anything specified is not).
- **Block diagram**: the five-layer hierarchy of Figure 4-1 as built.
- **Parameters and their effects**: `SYS_CLK_HZ`, `DATA_W`, `RD_FIFO_BLOCKS`,
  `WR_FIFO_BLOCKS`, `CRC_RETRIES`.
- **Sampling phases**: how many `SAMPLE_PHASE` settings exist at the nominal
  clock ratio, and which one was chosen.
- **Known limitations**.
- **References (R-IP-2)**: everything read -- SD Physical Layer Simplified
  Specification v6.00, LiteSDCard, application notes, forum posts -- and what
  was taken from each conceptually. Any third-party code in the delivery gets
  its own file, with origin and licence in a header comment, listed here
  (R-IP-3).

R-DEL-3: this must be sufficient for someone who did not write the core to
integrate it without contacting the author.

---

## Known limitations (draft notes toward the section above)

### The register map is compacted, and that deviates from R-IF-2

Table 5-1 gives each register its own offset, and the bullet above is explicit
that relocating a specified register is not permitted. The delivered map does
relocate them: it packs the table into shared words to stay inside the
Section 9 resource budget, so the last mapped offset is `0x24` rather than
`0x3C`.

| Offset | Word | Fields, with the Table 5-1 name kept as the field name |
|---|---|---|
| `0x00` | `VERSION` | RO |
| `0x04` | `CTRL_STATUS` | `CTRL` (W, byte 0, self-clearing), `STATUS` [7:0] RO, `ERR` [15:8] RO, `IRQ_STAT` [18:16] W1C, `IRQ_EN` [26:24] RW, `irq` [31] RO |
| `0x08` | `LBA` | RW 32 |
| `0x0C` | `XFER_CFG` | `BLOCKS` [23:0] RW, `XFER_DIR` [31] RW |
| `0x10` | `HW_CFG` | `CFG_CLK` [7:0] RW, `CFG_PHY` [13:8] RW |
| `0x14` | `CARD_BLK` | RO |
| `0x18` | `STAT_DATA` | RO |
| `0x1C` | `STAT_GAP` | RO |
| `0x20` | `STAT_BUSY` | RO |
| `0x24` | `STAT_RETRY` | RO |

`ultra_sd_pkg.sv` carries every Table 5-1 name as an alias onto the word it
now lives in, so RTL and testbenches still read in the spec's vocabulary.

Two consequences an integrator has to know, because they are not visible from
the names:

- **Two fields that share a word cannot be programmed in two accesses.** A
  write to `BLOCKS` is a write to the whole `XFER_CFG` word, so a second write
  aimed at `XFER_DIR` clears the `BLOCKS` that was just set. Program them
  together, or use `WSTRB`. The same holds for `CFG_CLK` / `CFG_PHY` and for
  `CTRL` / `IRQ_EN`.
- **A whole-word write to `0x04` pulses `CTRL`.** Setting `IRQ_EN` without
  starting a transfer means writing that offset with `WSTRB` = `0b1000`.

Offsets `0x28` upward answer SLVERR, which includes every offset Table 5-1
used above `0x24` -- so a host driver written against the table faults on its
first access rather than silently writing the wrong register.

`doc/checklist.md` carries "Register map exactly as Table 5-1 | R-IF-2" as an
open item. Closing it means reopening the map and re-measuring Section 9.

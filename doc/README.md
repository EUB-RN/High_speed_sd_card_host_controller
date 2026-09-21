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

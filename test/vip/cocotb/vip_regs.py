"""The register map as implemented, as the VIP sees it.

Written out by hand rather than parsed out of ultra_sd_pkg.sv: a test that
derives its expectations from the design under test cannot disagree with it.

A note on what this file tracks, because it is not Table 5-1 verbatim. The
delivered map is compacted: the registers Table 5-1 gives separate offsets to
are packed into shared words, with the spec's names surviving as field
positions inside them.

    0x00  VERSION    RO
    0x04  CTRL_STATUS   CTRL (W, byte 0, self-clearing pulses)
                        STATUS  [7:0]   RO
                        ERR     [15:8]  RO
                        IRQ_STAT[18:16] W1C
                        IRQ_EN  [26:24] RW
                        irq     [31]    RO
    0x08  LBA        RW 32
    0x0C  XFER_CFG      BLOCKS  [23:0]  RW
                        XFER_DIR[31]    RW
    0x10  HW_CFG        CFG_CLK [7:0]   RW
                        CFG_PHY [13:8]  RW
    0x14  CARD_BLK   RO
    0x18  STAT_DATA  RO
    0x1C  STAT_GAP   RO
    0x20  STAT_BUSY  RO
    0x24  STAT_RETRY RO

That packing is a deliberate area optimisation and it is a documented
deviation from R-IF-2 -- see the known limitations in doc/README.md. This file
follows the implementation because its job is to verify what was built; it is
not evidence that the deviation is resolved.
"""

REG_VERSION     = 0x00  # RO
REG_CTRL_STATUS = 0x04  # CTRL / STATUS / ERR / IRQ, one word
REG_LBA         = 0x08  # RW
REG_XFER_CFG    = 0x0C  # BLOCKS + XFER_DIR
REG_HW_CFG      = 0x10  # CFG_CLK + CFG_PHY
REG_CARD_BLK    = 0x14  # RO
REG_STAT_DATA   = 0x18  # RO
REG_STAT_GAP    = 0x1C  # RO
REG_STAT_BUSY   = 0x20  # RO
REG_STAT_RETRY  = 0x24  # RO

# The spec's names, resolved to the word each one now lives in. Tests read
# better with these, and they are the same aliases ultra_sd_pkg.sv carries --
# but a write to one field is a write to the whole word, so two of these
# sharing an address can never be programmed in two separate accesses.
REG_CTRL      = REG_CTRL_STATUS
REG_STATUS    = REG_CTRL_STATUS
REG_ERR       = REG_CTRL_STATUS
REG_IRQ_EN    = REG_CTRL_STATUS
REG_IRQ_STAT  = REG_CTRL_STATUS
REG_BLOCKS    = REG_XFER_CFG
REG_XFER      = REG_XFER_CFG
REG_CFG_CLK   = REG_HW_CFG
REG_CFG_PHY   = REG_HW_CFG

VERSION_MAGIC = 0x5344  # 'SD', the upper half of VERSION

# Field positions inside the shared words.
CTRL_START_BIT      = 0
CTRL_ABORT_BIT      = 1
CTRL_STAT_CLEAR_BIT = 2
CTRL_SOFT_RESET_BIT = 3
STATUS_LSB          = 0
ERR_LSB             = 8
IRQ_STAT_LSB        = 16
IRQ_EN_LSB          = 24
IRQ_W               = 3
XFER_DIR_BIT        = 31
CFG_CLK_LSB         = 0
CFG_PHY_LSB         = 8

# The highest mapped offset. Anything above this and inside the 256-byte
# window is unmapped, and R-IF-2 says an access there answers SLVERR.
LAST_MAPPED = 0x24

# Read/write registers a whole-word write can be swept over, and the mask of
# bits that actually stick, so a read-back check knows what to expect.
#
# CTRL_STATUS is deliberately not here. Its only writable-and-readable field is
# IRQ_EN, but a whole-word write to that offset also lands on the CTRL byte --
# which pulses START and sets a transfer going. Sweeping it with random data
# would be issuing random transfers, so it gets its own strobed test instead.
RW_REGS = {
    REG_LBA:      0xFFFF_FFFF,  # LBA     = 32
    REG_XFER_CFG: 0x80FF_FFFF,  # BLOCKS  = 24, XFER_DIR at 31
    REG_HW_CFG:   0x0000_3FFF,  # CFG_CLK = 8, CFG_PHY = 6 at bit 8
}

# The bits of CTRL_STATUS a write reaches and a read returns.
CTRL_STATUS_RW_MASK = 0x0700_0000  # IRQ_EN at bit 24

# Read-only registers: a write must not change them, and must not error
# either -- they are RO, not absent. CTRL_STATUS is excluded: part of it is
# writable, so it belongs to neither list wholesale.
RO_REGS = [
    REG_VERSION, REG_CARD_BLK,
    REG_STAT_DATA, REG_STAT_GAP, REG_STAT_BUSY, REG_STAT_RETRY,
]

# Unmapped offsets inside the window, used for the SLVERR path (R-IF-2). The
# first two sit in the gap the compaction opened up between LAST_MAPPED and
# the offsets Table 5-1 once used, which is exactly where a stale driver
# written against the table would land.
UNMAPPED = [0x28, 0x2C, 0x38, 0x3C, 0x40, 0x80, 0xFC]


def xfer_cfg(blocks, write):
    """BLOCKS and XFER_DIR as the single word they share.

    They used to be two registers, so programming them took two writes. They
    are one word now: a second write would clear what the first put there.
    """
    return (blocks & 0x00FF_FFFF) | ((1 << XFER_DIR_BIT) if write else 0)

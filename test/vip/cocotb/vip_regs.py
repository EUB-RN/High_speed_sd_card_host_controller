"""Table 5-1 as the VIP sees it.

Kept in one place, and deliberately written out by hand rather than parsed out
of ultra_sd_pkg.sv: a test that derives its expectations from the design under
test cannot disagree with it. The specification is the source, so the
specification is what is typed here.
"""

REG_VERSION    = 0x00  # RO
REG_CTRL       = 0x04  # W1S, self-clearing pulses
REG_STATUS     = 0x08  # RO
REG_ERR        = 0x0C  # RO
REG_LBA        = 0x10  # RW
REG_BLOCKS     = 0x14  # RW
REG_XFER       = 0x18  # RW
REG_CFG_CLK    = 0x1C  # RW
REG_CFG_PHY    = 0x20  # RW
REG_CARD_BLK   = 0x24  # RO
REG_STAT_DATA  = 0x28  # RO
REG_STAT_GAP   = 0x2C  # RO
REG_STAT_BUSY  = 0x30  # RO
REG_STAT_RETRY = 0x34  # RO
REG_IRQ_EN     = 0x38  # RW
REG_IRQ_STAT   = 0x3C  # W1C

VERSION_MAGIC = 0x5344  # 'SD', the upper half of VERSION

# The highest specified offset. Anything above this and inside the 256-byte
# window is unmapped, and R-IF-2 says an access there answers SLVERR.
LAST_MAPPED = 0x3C

# Read/write registers and the mask of bits that actually stick, so a
# read-back check knows what to expect. Width comes from Table 5-1, not from
# the RTL.
RW_REGS = {
    REG_LBA:     0xFFFF_FFFF,  # LBA_W     = 32
    REG_BLOCKS:  0x00FF_FFFF,  # BLOCKS_W  = 24
    REG_XFER:    0x0000_0001,  # DIR only
    REG_CFG_CLK: 0x0000_00FF,  # CFG_CLK_W = 8
    REG_CFG_PHY: 0x0000_003F,  # CFG_PHY_W = 6
    REG_IRQ_EN:  0x0000_0007,  # IRQ_W     = 3
}

# Read-only registers: a write must not change them, and must not error
# either -- Table 5-1 makes them RO, not absent.
RO_REGS = [
    REG_VERSION, REG_STATUS, REG_ERR, REG_CARD_BLK,
    REG_STAT_DATA, REG_STAT_GAP, REG_STAT_BUSY, REG_STAT_RETRY,
]

# Unmapped offsets inside the window, used for the SLVERR path (R-IF-2).
UNMAPPED = [0x40, 0x44, 0x80, 0xC0, 0xFC]

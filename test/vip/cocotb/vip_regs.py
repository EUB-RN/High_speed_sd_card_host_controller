"""The register map as implemented, as the VIP sees it.

Written out by hand rather than parsed out of ultra_sd_pkg.sv: a test that
derives its expectations from the design under test cannot disagree with it.

This is now Table 5-1 verbatim, one register per row:

    0x00  VERSION     RO   [31:16] magic 0x5344, [15:8] major, [7:0] minor
    0x04  CTRL        W1S  [0] START [1] ABORT [2] STAT_CLEAR [3] SOFT_RESET
    0x08  STATUS      RO   [0] BUSY [1] DONE [2] CARD_PRESENT [3] CARD_READY
                           [5:4] SPEED_MODE [7:6] BUS_WIDTH
    0x0C  ERR         RO   [7:0] error code, Table 5-3
    0x10  LBA         RW   [31:0]
    0x14  BLOCKS      RW   [23:0]
    0x18  XFER        RW   [0] DIR, 0 = read, 1 = write
    0x1C  CFG_CLK     RW   [7:0] divisor
    0x20  CFG_PHY     RW   [3:0] SAMPLE_PHASE [4] FORCE_1BIT [5] FORCE_DS
    0x24  CARD_BLK    RO   capacity in 512-byte blocks
    0x28  STAT_DATA   RO
    0x2C  STAT_GAP    RO
    0x30  STAT_BUSY   RO
    0x34  STAT_RETRY  RO   [15:0] CRC retries, [31:16] command retries
    0x38  IRQ_EN      RW   [0] DONE [1] ERR [2] CARD_CHANGE
    0x3C  IRQ_STAT    W1C  [0] DONE [1] ERR [2] CARD_CHANGE

It did not always say that. The delivered map used to be a compacted ten-word
layout -- CTRL, STATUS, ERR, IRQ_EN and IRQ_STAT packed into one word at 0x04,
BLOCKS and XFER into 0x0C, CFG_CLK and CFG_PHY into 0x10 -- recorded as a
deliberate area saving and a documented deviation from R-IF-2. It was not a
deviation anybody could afford: Section 5 is normative and exact, the client's
harness drives these offsets, and on that harness a write to CTRL.START would
have landed on STATUS. The packing also had a functional edge of its own --
setting a CFG_PHY force bit with an ordinary 32-bit write zeroed the clock
divisor, because they shared a word.
"""

REG_VERSION    = 0x00  # RO
REG_CTRL       = 0x04  # W1S, self-clearing
REG_STATUS     = 0x08  # RO
REG_ERR        = 0x0C  # RO
REG_LBA        = 0x10  # RW
REG_BLOCKS     = 0x14  # RW, 24 bits
REG_XFER       = 0x18  # RW, 1 bit
REG_CFG_CLK    = 0x1C  # RW, 8 bits
REG_CFG_PHY    = 0x20  # RW, 6 bits
REG_CARD_BLK   = 0x24  # RO
REG_STAT_DATA  = 0x28  # RO
REG_STAT_GAP   = 0x2C  # RO
REG_STAT_BUSY  = 0x30  # RO
REG_STAT_RETRY = 0x34  # RO
REG_IRQ_EN     = 0x38  # RW
REG_IRQ_STAT   = 0x3C  # W1C

VERSION_MAGIC = 0x5344  # 'SD', the upper half of VERSION

# Field positions. Each field is at the bottom of its own register now, except
# XFER.DIR, which Table 5-1 puts at bit 0 of its own word.
CTRL_START_BIT      = 0
CTRL_ABORT_BIT      = 1
CTRL_STAT_CLEAR_BIT = 2
CTRL_SOFT_RESET_BIT = 3
STATUS_LSB          = 0
STATUS_BUSY_BIT     = 0
STATUS_DONE_BIT     = 1
STATUS_CARD_PRES    = 2
STATUS_CARD_RDY     = 3
STATUS_SPEED_LSB    = 4
STATUS_WIDTH_LSB    = 6
ERR_LSB             = 0
IRQ_STAT_LSB        = 0
IRQ_EN_LSB          = 0
IRQ_W               = 3
XFER_DIR_BIT        = 0
CFG_CLK_LSB         = 0
CFG_PHY_LSB         = 0
CFG_PHY_PHASE_LSB   = 0
CFG_PHY_FORCE_1BIT  = 4
CFG_PHY_FORCE_DS    = 5

# The highest mapped offset. Anything above this and inside the 256-byte
# window is unmapped, and R-IF-2 says an access there answers SLVERR.
LAST_MAPPED = 0x3C

# Read/write registers a whole-word write can be swept over, and the mask of
# bits that actually stick, so a read-back check knows what to expect.
#
# CTRL is deliberately not here: writing it pulses START and sets a transfer
# going, so sweeping it with random data would be issuing random transfers. It
# gets its own directed test instead. IRQ_STAT is W1C, which is also not a
# read-back relationship.
RW_REGS = {
    REG_LBA:     0xFFFF_FFFF,  # 32 bits
    REG_BLOCKS:  0x00FF_FFFF,  # 24 bits
    REG_XFER:    0x0000_0001,  # DIR only
    REG_CFG_CLK: 0x0000_00FF,  # 8-bit divisor
    REG_CFG_PHY: 0x0000_003F,  # 4-bit phase + two force bits
    REG_IRQ_EN:  0x0000_0007,  # three sources
}

# Read-only registers: a write must not change them, and must not error
# either -- they are RO, not absent.
RO_REGS = [
    REG_VERSION, REG_STATUS, REG_ERR, REG_CARD_BLK,
    REG_STAT_DATA, REG_STAT_GAP, REG_STAT_BUSY, REG_STAT_RETRY,
]

# Unmapped offsets inside the window, used for the SLVERR path (R-IF-2). The
# map now fills 0x00..0x3C with no holes, so every one of these is above it --
# which is what Section 5 means by "you may add registers in the unused
# address space above 0x3C".
UNMAPPED = [0x40, 0x44, 0x60, 0x80, 0xC0, 0xFC]

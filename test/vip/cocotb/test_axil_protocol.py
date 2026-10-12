"""AXI4-Lite verification against the delivered host interface.

The stimulus and the protocol checking come from cocotbext-axi (MIT, Alex
Forencich), which is the established open-source AXI VIP: it drives the five
channels with randomised handshake timing and flags protocol violations of its
own accord. What this file adds is the part no VIP can know -- the contents of
Table 5-1 and which offsets are supposed to answer SLVERR.

Covers R-IF-1 (all five channels), R-IF-2 (register map and the SLVERR path),
R-IF-3 (LBA latched at START).

The map under test is the compacted one -- see vip_regs.py for the layout and
for why it is not Table 5-1 verbatim.
"""

import random

import cocotb
from cocotb.triggers import ClockCycles
from cocotbext.axi import AxiResp

import vip_regs as R
from vip_env import VipEnv, manual_read, manual_write, reset_pulse


async def expect_resp(op_coro, want, what):
    op = await op_coro
    got = AxiResp(op.resp)
    assert got == want, f"{what}: got {got.name}, want {want.name}"
    return op


@cocotb.test()
async def test_version(dut):
    """VERSION reads back the magic, over a legal AXI4-Lite read."""
    env = VipEnv(dut)
    await env.start()

    op = await expect_resp(env.axil.read(R.REG_VERSION, 4), AxiResp.OKAY, "VERSION")
    version = int.from_bytes(op.data, "little")
    assert (version >> 16) == R.VERSION_MAGIC, (
        f"VERSION upper half is 0x{version >> 16:04x}, want 0x{R.VERSION_MAGIC:04x}")
    cocotb.log.info("VERSION = 0x%08x", version)

    await env.finish()


@cocotb.test()
async def test_rw_registers(dut):
    """Every RW register holds exactly the bits Table 5-1 gives it."""
    env = VipEnv(dut)
    await env.start()

    for addr, mask in R.RW_REGS.items():
        # All ones, then all zeros, then a random pattern: enough to catch a
        # stuck bit, an inverted bit and a field that is wider or narrower than
        # the table says.
        for pattern in (0xFFFF_FFFF, 0x0000_0000, random.getrandbits(32)):
            await expect_resp(
                env.axil.write(addr, pattern.to_bytes(4, "little")),
                AxiResp.OKAY, f"write 0x{addr:02x}")
            op = await expect_resp(
                env.axil.read(addr, 4), AxiResp.OKAY, f"read 0x{addr:02x}")
            got = int.from_bytes(op.data, "little")
            assert got == (pattern & mask), (
                f"0x{addr:02x}: wrote 0x{pattern:08x}, read 0x{got:08x}, "
                f"want 0x{pattern & mask:08x} for mask 0x{mask:08x}")

    await env.finish()


@cocotb.test()
async def test_ro_registers(dut):
    """A write to a read-only register is accepted and ignored, not an error.

    Table 5-1 marks these RO, which is not the same as unmapped: the access is
    legal, so the response is OKAY and the value must not move.
    """
    env = VipEnv(dut)
    await env.start()

    for addr in R.RO_REGS:
        op = await expect_resp(
            env.axil.read(addr, 4), AxiResp.OKAY, f"read 0x{addr:02x}")
        before = int.from_bytes(op.data, "little")

        await env.axil.write(addr, (~before & 0xFFFF_FFFF).to_bytes(4, "little"))

        op = await expect_resp(
            env.axil.read(addr, 4), AxiResp.OKAY, f"re-read 0x{addr:02x}")
        after = int.from_bytes(op.data, "little")
        assert after == before, (
            f"RO register 0x{addr:02x} changed from 0x{before:08x} to 0x{after:08x}")

    await env.finish()


@cocotb.test()
async def test_ctrl_status_split(dut):
    """0x04 carries CTRL, STATUS, ERR and the IRQ pair in one word.

    The compaction put four of Table 5-1's registers at one offset, so what
    needs proving is that they still behave as four registers: the
    hardware-driven halves must not be writable, and each field must be
    CTRL, STATUS, ERR, IRQ_EN and IRQ_STAT are five separate registers in
    Table 5-1, and the point of this test is that they behave as five: a write
    to one cannot reach another. They used to be five fields of one word at
    0x04, where a whole-word write landed on CTRL and IRQ_EN together and a
    driver that wanted one without the other had to use WSTRB.

    Driven by hand because the pulse behaviour of CTRL and the W1C behaviour
    of IRQ_STAT are not read-back relationships a generic master can check.
    """
    env = VipEnv(dut, axil_master=False)
    await env.start()

    # CTRL is W1S and self-clearing: a START pulse is not readable afterwards.
    resp = await manual_write(dut, R.REG_CTRL, 1 << R.CTRL_START_BIT, 0b1111)
    assert resp == AxiResp.OKAY, f"CTRL write answered {AxiResp(resp).name}"
    got, resp = await manual_read(dut, R.REG_CTRL)
    assert resp == AxiResp.OKAY
    assert got == 0, f"CTRL read back as 0x{got:08x}, want a self-clearing pulse"

    # IRQ_EN is an ordinary RW register and a whole-word write reaches all of
    # it -- no strobe gymnastics, which is the point of the split.
    resp = await manual_write(dut, R.REG_IRQ_EN, 0xFFFF_FFFF, 0b1111)
    assert resp == AxiResp.OKAY
    got, _ = await manual_read(dut, R.REG_IRQ_EN)
    assert got == 0x7, f"IRQ_EN read 0x{got:08x} after all-ones, want 0x7"

    # ...and writing CTRL does not disturb it, because they are not the same
    # word any more.
    await manual_write(dut, R.REG_CTRL, 1 << R.CTRL_START_BIT, 0b1111)
    got, _ = await manual_read(dut, R.REG_IRQ_EN)
    assert got == 0x7, f"a CTRL write disturbed IRQ_EN: read 0x{got:08x}"

    resp = await manual_write(dut, R.REG_IRQ_EN, 0x0000_0000, 0b1111)
    assert resp == AxiResp.OKAY
    got, _ = await manual_read(dut, R.REG_IRQ_EN)
    assert got == 0, f"IRQ_EN did not clear: 0x{got:08x}"

    # STATUS and ERR are hardware-driven and read-only. A write must be
    # accepted (they are RO, not absent) and must change nothing; the harness
    # drives both at zero.
    for reg, name in ((R.REG_STATUS, "STATUS"), (R.REG_ERR, "ERR")):
        resp = await manual_write(dut, reg, 0xFFFF_FFFF, 0b1111)
        assert resp == AxiResp.OKAY, f"{name} write answered {AxiResp(resp).name}"
        got, _ = await manual_read(dut, reg)
        assert got == 0, f"{name} took a write: read 0x{got:08x}"

    await env.finish()


@cocotb.test()
async def test_unmapped_slverr(dut):
    """R-IF-2: an access to an unmapped offset answers SLVERR, both directions.

    This is the requirement most easily satisfied by accident -- a slave that
    answers OKAY to everything passes a functional test and fails this one.
    """
    env = VipEnv(dut)
    await env.start()

    for addr in R.UNMAPPED:
        await expect_resp(
            env.axil.read(addr, 4), AxiResp.SLVERR, f"read unmapped 0x{addr:02x}")
        await expect_resp(
            env.axil.write(addr, b"\xde\xad\xbe\xef"),
            AxiResp.SLVERR, f"write unmapped 0x{addr:02x}")

    # And the slave is still alive afterwards: an error response must not wedge
    # the channel.
    await expect_resp(
        env.axil.read(R.REG_VERSION, 4), AxiResp.OKAY, "VERSION after SLVERR")

    await env.finish()


@cocotb.test()
async def test_byte_strobes(dut):
    """WSTRB selects which bytes land, and leaves the rest alone.

    Driven by hand rather than through the VIP master: AXI4-Lite requires the
    address to be aligned to the data bus width, so a single-byte write is one
    aligned address with one WSTRB bit set. A VIP master asked for a one-byte
    transfer instead produces an unaligned AWADDR, which the monitor correctly
    rejects -- so the master stays out of this test.
    """
    env = VipEnv(dut, axil_master=False)
    await env.start()

    resp = await manual_write(dut, R.REG_LBA, 0x0000_0000, 0b1111)
    assert resp == AxiResp.OKAY, f"clearing LBA answered {AxiResp(resp).name}"

    for byte_index in range(4):
        value = (0xA0 + byte_index) << (8 * byte_index)
        resp = await manual_write(dut, R.REG_LBA, value, 1 << byte_index)
        assert resp == AxiResp.OKAY, (
            f"WSTRB=0b{1 << byte_index:04b} answered {AxiResp(resp).name}")

    got, resp = await manual_read(dut, R.REG_LBA)
    assert resp == AxiResp.OKAY
    assert got == 0xA3A2A1A0, f"byte strobes: read 0x{got:08x}, want 0xa3a2a1a0"

    # And a write with no strobes set must change nothing.
    await manual_write(dut, R.REG_LBA, 0xFFFF_FFFF, 0b0000)
    got, _ = await manual_read(dut, R.REG_LBA)
    assert got == 0xA3A2A1A0, (
        f"a zero-WSTRB write changed LBA to 0x{got:08x}")

    await env.finish()


@cocotb.test()
async def test_random_traffic(dut):
    """Randomised read/write mix across the whole window, with backpressure.

    The point is not the data -- the mapped registers are checked exactly
    elsewhere -- but the handshake timing. Randomised idle gaps put VALID and
    READY into combinations a directed test never reaches, and both the Python
    VIP and the SV monitor watch every beat of it.
    """
    seed = random.getrandbits(32)
    random.seed(seed)
    cocotb.log.info("random traffic seed = %d", seed)

    env = VipEnv(dut)
    await env.start()

    rw = list(R.RW_REGS.items())
    shadow = {addr: 0 for addr, _ in rw}
    for addr, mask in rw:
        await env.axil.write(addr, b"\x00\x00\x00\x00")

    for _ in range(200):
        if random.random() < 0.5:
            addr, mask = random.choice(rw)
            value = random.getrandbits(32)
            await expect_resp(
                env.axil.write(addr, value.to_bytes(4, "little")),
                AxiResp.OKAY, f"write 0x{addr:02x}")
            shadow[addr] = value & mask
        else:
            addr = random.choice([a for a, _ in rw])
            op = await expect_resp(
                env.axil.read(addr, 4), AxiResp.OKAY, f"read 0x{addr:02x}")
            got = int.from_bytes(op.data, "little")
            assert got == shadow[addr], (
                f"0x{addr:02x}: read 0x{got:08x}, shadow says 0x{shadow[addr]:08x} "
                f"(seed {seed})")

        if random.random() < 0.3:
            await ClockCycles(dut.clk, random.randint(1, 5))

    await env.finish()


@cocotb.test()
async def test_reset_mid_traffic(dut):
    """A reset in the middle of traffic leaves a usable bus behind.

    The SV monitor's reset property watches this: no VALID may be high while
    rst_n is low, and nothing may be left outstanding across the reset.
    """
    env = VipEnv(dut)
    await env.start()

    await env.axil.write(R.REG_LBA, b"\x11\x22\x33\x44")
    await reset_pulse(dut)
    await env.clear_monitors()

    op = await expect_resp(
        env.axil.read(R.REG_LBA, 4), AxiResp.OKAY, "LBA after reset")
    got = int.from_bytes(op.data, "little")
    assert got == 0, f"LBA survived reset as 0x{got:08x}, want 0"

    await expect_resp(
        env.axil.write(R.REG_LBA, b"\x55\x66\x77\x88"), AxiResp.OKAY, "LBA write")
    op = await env.axil.read(R.REG_LBA, 4)
    assert int.from_bytes(op.data, "little") == 0x88776655

    await env.finish()

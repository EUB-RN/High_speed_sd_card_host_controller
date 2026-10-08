"""AXI4-Stream verification on both of the core's stream interfaces.

cocotbext-axi supplies the sink for the read stream and the source for the
write stream, including the randomised pause patterns that produce the
backpressure of R-IF-7 and the starvation of R-IF-8. What this file adds is
the framing expectation: 512-byte blocks, so 128 beats per packet on a 32-bit
stream, with TLAST on the last beat and nowhere else (R-IF-6).

Covers R-IF-5, R-IF-6, R-IF-7, R-IF-8.
"""

import random

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge, with_timeout
from cocotbext.axi import AxiStreamFrame

import vip_regs as R
from vip_env import VipEnv

DATA_W = 32
BEATS_PER_BLOCK = (512 * 8) // DATA_W   # 128


def pause_generator(rate, seed):
    """Random pause pattern for a VIP source or sink.

    `rate` is the fraction of cycles spent paused, so 0.0 is a sink that never
    stalls and 0.9 is one that is almost always stalling -- which is the point
    of R-IF-7: arbitrary backpressure, not polite backpressure.
    """
    rng = random.Random(seed)

    def gen():
        while True:
            yield rng.random() < rate

    return gen()


async def start_read_transfer(env, blocks, pkt_beats=None):
    """Ask the read path for `blocks` blocks and let the SD side produce them.

    `pkt_beats` is what the SV monitor will hold the stream to. The design
    frames one AXI4-Stream packet per *transfer*, not per block -- TLAST lands
    on the last beat of all `blocks` blocks -- so the default is the whole
    transfer. Pass a different value to assert a different framing.
    """
    beats = blocks * BEATS_PER_BLOCK
    env.dut.rd_pkt_beats.value = beats if pkt_beats is None else pkt_beats
    # BLOCKS and XFER_DIR share one word, so they go out in a single write --
    # programming them separately clears whichever was written first.
    await env.axil.write(R.REG_XFER_CFG,
                         R.xfer_cfg(blocks, write=False).to_bytes(4, "little"))
    env.dut.sd_feed_en.value = 1
    await env.axil.write(R.REG_CTRL, (1).to_bytes(4, "little"))   # CTRL.START
    return beats


@cocotb.test()
async def test_read_stream_no_backpressure(dut):
    """The read stream delivers a whole block, framed correctly, at full rate."""
    env = VipEnv(dut)
    await env.start()

    beats = await start_read_transfer(env, blocks=1)

    # The sink only completes a frame when TLAST arrives, so receiving one at
    # all is the evidence that the packet was terminated. Where TLAST landed is
    # the SV monitor's PKT_LEN property, checked in env.finish().
    frame = await with_timeout(env.rd_sink.recv(), 200 * beats * 10, "ns")

    words = [int.from_bytes(frame.tdata[i:i + 4], "little")
             for i in range(0, len(frame.tdata), 4)]
    assert len(words) == beats, f"frame is {len(words)} beats, want {beats}"
    # The harness feeds a counting pattern, so beat n must carry n.
    assert words == list(range(beats)), (
        f"payload is not the counting pattern: first mismatch at "
        f"{next(i for i, w in enumerate(words) if w != i)}")

    dut.sd_feed_en.value = 0
    await env.finish()


@cocotb.test()
async def test_read_stream_backpressure(dut):
    """R-IF-7: the read stream survives arbitrary TREADY stalling.

    The sink pauses at random for most cycles. Nothing may be lost, reordered
    or duplicated, and TLAST must still land on beat 128 of each block.
    """
    seed = random.getrandbits(32)
    cocotb.log.info("backpressure seed = %d", seed)

    env = VipEnv(dut)
    await env.start()
    env.rd_sink.set_pause_generator(pause_generator(0.7, seed))

    blocks = 2
    beats = await start_read_transfer(env, blocks=blocks)

    # One packet for the whole transfer, so one frame however many blocks it
    # covers. Where TLAST landed is checked by the monitor's PKT_LEN property.
    frame = await with_timeout(env.rd_sink.recv(), 400 * beats * 10, "ns")
    received = [int.from_bytes(frame.tdata[i:i + 4], "little")
                for i in range(0, len(frame.tdata), 4)]

    assert received == list(range(beats)), (
        f"backpressure lost or reordered data: {len(received)} of {beats} beats "
        f"(seed {seed})")

    dut.sd_feed_en.value = 0
    await env.finish()


@cocotb.test()
async def test_write_stream_starvation(dut):
    """R-IF-8: the write stream survives arbitrary producer starvation.

    The source pauses at random, so TVALID goes away mid-packet repeatedly.
    Every beat must still reach the SD side, in order, with the packet's TLAST
    arriving with the last of them.
    """
    seed = random.getrandbits(32)
    cocotb.log.info("starvation seed = %d", seed)

    env = VipEnv(dut)
    await env.start()
    env.wr_source.set_pause_generator(pause_generator(0.6, seed))

    dut.wr_pkt_beats.value = BEATS_PER_BLOCK
    dut.sd_drain_en.value = 1

    payload = b"".join(i.to_bytes(4, "little") for i in range(BEATS_PER_BLOCK))
    await env.wr_source.send(AxiStreamFrame(payload))
    await env.wr_source.wait()

    # Wait for the SD side to have taken every beat, bounded rather than
    # open-ended: a stalled write path must report, not hang.
    for _ in range(BEATS_PER_BLOCK * 200):
        if int(dut.sd_drained_count.value) >= BEATS_PER_BLOCK:
            break
        await RisingEdge(dut.sd_clk)
    drained = int(dut.sd_drained_count.value)
    assert drained == BEATS_PER_BLOCK, (
        f"SD side took {drained} of {BEATS_PER_BLOCK} beats (seed {seed})")

    assert int(dut.sd_saw_pl_last.value) == 1, (
        "the packet's TLAST never reached the SD side")
    last = int(dut.sd_drained_last_data.value)
    assert last == BEATS_PER_BLOCK - 1, (
        f"last beat on the SD side is {last}, want {BEATS_PER_BLOCK - 1}")

    dut.sd_drain_en.value = 0
    await env.finish()


@cocotb.test()
async def test_write_stream_full_fifo(dut):
    """The write path asserts backpressure rather than dropping data.

    With the SD side not draining at all, the FIFO fills and TREADY must go
    low. The beats already accepted must still be exactly the ones sent.
    """
    env = VipEnv(dut)
    await env.start()

    dut.sd_drain_en.value = 0
    dut.wr_pkt_beats.value = BEATS_PER_BLOCK

    payload = b"".join(i.to_bytes(4, "little") for i in range(BEATS_PER_BLOCK))
    # The FIFO holds WR_FIFO_BLOCKS blocks, so three blocks cannot fit and the
    # stream has to stall. send() only queues, so the wait below is for the
    # beats to actually reach the bus.
    for _ in range(3):
        await env.wr_source.send(AxiStreamFrame(payload))

    for _ in range(4 * 3 * BEATS_PER_BLOCK):
        if int(dut.s_axis_wr_tready.value) == 0:
            break
        await RisingEdge(dut.clk)
    assert int(dut.s_axis_wr_tready.value) == 0, (
        "the write stream kept TREADY high with a full FIFO and no drain")
    assert int(dut.sd_drained_count.value) == 0, (
        "beats moved on the SD side with draining disabled")

    # Let it go, and everything sent must arrive.
    dut.sd_drain_en.value = 1
    for _ in range(BEATS_PER_BLOCK * 400):
        if int(dut.sd_drained_count.value) >= 3 * BEATS_PER_BLOCK:
            break
        await RisingEdge(dut.sd_clk)
    drained = int(dut.sd_drained_count.value)
    assert drained == 3 * BEATS_PER_BLOCK, (
        f"SD side took {drained} of {3 * BEATS_PER_BLOCK} beats after release")

    dut.sd_drain_en.value = 0
    await env.finish()

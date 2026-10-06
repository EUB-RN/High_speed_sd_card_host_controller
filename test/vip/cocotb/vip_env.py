"""Shared environment for the cocotbext-axi tests.

Brings up the two clock domains, releases both resets in the order the design
expects, attaches the Python VIP, and -- at the end of every test -- reads the
verdict out of the SystemVerilog monitors compiled into the same harness.

That last part is the point of running both: cocotbext-axi is the maintained,
widely used checker, and our own monitors are the ones that can run without
Python in the other test categories. Checking them against each other on
identical traffic is what makes the SV monitors trustworthy there.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotbext.axi import (
    AxiLiteBus, AxiLiteMaster, AxiStreamBus, AxiStreamSink, AxiStreamSource,
)

# 100 MHz AXI domain, the nominal SYS_CLK_HZ of Figure 5-1.
AXI_CLK_NS = 10
# 25 MHz SD domain. Deliberately not an integer-friendly relationship with the
# AXI clock in any way the design could exploit: the ratio changes at runtime
# with CFG_CLK, so nothing may assume one (R-DEG-1).
SD_CLK_NS = 41


class VipEnv:
    """The harness, its clocks, and both sets of checkers."""

    def __init__(self, dut, axil_master=True):
        self.dut = dut
        # The VIP master drives the AXI4-Lite request signals on every cycle of
        # its run loop, so a test that needs to place its own values on the bus
        # -- a partial WSTRB, which the master cannot express without an
        # unaligned address AXI4-Lite forbids -- has to do without it.
        self.axil = None
        if axil_master:
            self.axil = AxiLiteMaster(
                AxiLiteBus.from_prefix(dut, "s_axil"),
                dut.clk, dut.rst_n, reset_active_level=False,
            )
        # The read stream flows card -> host, so the VIP is the sink; the write
        # stream flows host -> card, so the VIP is the source.
        self.rd_sink = AxiStreamSink(
            AxiStreamBus.from_prefix(dut, "m_axis_rd"),
            dut.clk, dut.rst_n, reset_active_level=False,
        )
        self.wr_source = AxiStreamSource(
            AxiStreamBus.from_prefix(dut, "s_axis_wr"),
            dut.clk, dut.rst_n, reset_active_level=False,
        )
        # The SystemVerilog monitors compiled into the harness. They are read
        # through their signals, not called: cocotb drives and samples HDL
        # signals and cannot invoke an SV task, which is why each monitor
        # carries a `clear_i` port and exposes its counters as variables.
        self.sv_monitors = [
            ("sv.axil", dut.mon_axil),
            ("sv.axis_rd", dut.mon_axis_rd),
            ("sv.axis_wr", dut.mon_axis_wr),
        ]

    async def start(self):
        cocotb.start_soon(Clock(self.dut.clk, AXI_CLK_NS, unit="ns").start())
        cocotb.start_soon(Clock(self.dut.sd_clk, SD_CLK_NS, unit="ns").start())

        self.dut.sd_feed_en.value = 0
        self.dut.sd_drain_en.value = 0
        self.dut.mon_clear.value = 0
        self.dut.rd_pkt_beats.value = 0
        self.dut.wr_pkt_beats.value = 0

        if self.axil is None:
            idle_axil(self.dut)

        self.dut.rst_n.value = 0
        self.dut.sd_rst_n.value = 0
        await ClockCycles(self.dut.clk, 10)
        self.dut.rst_n.value = 1
        self.dut.sd_rst_n.value = 1
        await ClockCycles(self.dut.clk, 5)

        # The SV monitors watched the reset itself, which is a property worth
        # keeping, but their transaction counters should start from the first
        # real access.
        await self.clear_monitors()

    async def clear_monitors(self):
        self.dut.mon_clear.value = 1
        await ClockCycles(self.dut.clk, 1)
        self.dut.mon_clear.value = 0
        self.dut.rd_pkt_beats.value = 0
        self.dut.wr_pkt_beats.value = 0
        await ClockCycles(self.dut.clk, 1)

    async def finish(self, drained=True):
        """Collect the verdict from the SystemVerilog monitors.

        `drained` is False for a test that deliberately ends mid-packet, where
        an unterminated stream is the expected outcome rather than a failure.
        """
        await ClockCycles(self.dut.clk, 20)

        failures = []
        for name, mon in self.sv_monitors:
            n_viol = int(mon.n_viol.value)
            n_checks = int(mon.n_checks.value)
            cocotb.log.info(
                "%s: %d armed checks, %d violations", name, n_checks, n_viol)
            if n_viol:
                failures.append(
                    f"{name}: {n_viol} violations, fired=0b"
                    f"{int(mon.fired.value):b}")

        # The drain properties are evaluated here rather than inside the
        # monitors, because only the test knows when its stimulus is over.
        if drained:
            aw = int(self.dut.mon_axil.aw_acc.value)
            w = int(self.dut.mon_axil.w_acc.value)
            b = int(self.dut.mon_axil.b_acc.value)
            ar = int(self.dut.mon_axil.ar_acc.value)
            r = int(self.dut.mon_axil.r_acc.value)
            cocotb.log.info(
                "sv.axil transactions: AW=%d W=%d B=%d AR=%d R=%d", aw, w, b, ar, r)
            if not (aw == w == b):
                failures.append(f"writes left unanswered: AW={aw} W={w} B={b}")
            if ar != r:
                failures.append(f"reads left unanswered: AR={ar} R={r}")
            for name, mon in self.sv_monitors[1:]:
                partial = int(mon.beat_in_pkt.value)
                if partial:
                    failures.append(
                        f"{name}: ended {partial} beats into an unterminated packet")

        assert not failures, "SystemVerilog monitors disagreed: " + "; ".join(failures)


async def reset_pulse(dut, cycles=6):
    """Assert and release both resets again, mid-test."""
    dut.rst_n.value = 0
    dut.sd_rst_n.value = 0
    await ClockCycles(dut.clk, cycles)
    dut.rst_n.value = 1
    dut.sd_rst_n.value = 1
    await ClockCycles(dut.clk, 4)


# -----------------------------------------------------------------------------
# Hand-driven AXI4-Lite, for the one thing the VIP master cannot express.
#
# AXI4-Lite requires every access to be aligned to the data bus width, so a
# single-byte write is an aligned address with a single WSTRB bit set -- not an
# unaligned address, which is what a VIP master produces when asked for a
# one-byte transfer. These helpers exist for that case and nothing else.
# -----------------------------------------------------------------------------

def idle_axil(dut):
    dut.s_axil_awaddr.value = 0
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wdata.value = 0
    dut.s_axil_wstrb.value = 0
    dut.s_axil_wvalid.value = 0
    dut.s_axil_bready.value = 0
    dut.s_axil_araddr.value = 0
    dut.s_axil_arvalid.value = 0
    dut.s_axil_rready.value = 0


async def manual_write(dut, addr, data, strb, timeout_cycles=64):
    """One AXI4-Lite write beat with an explicit WSTRB. Returns BRESP."""
    dut.s_axil_awaddr.value = addr
    dut.s_axil_wdata.value = data
    dut.s_axil_wstrb.value = strb
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wvalid.value = 1
    dut.s_axil_bready.value = 1

    aw_done = w_done = False
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if not aw_done and int(dut.s_axil_awready.value):
            aw_done = True
            dut.s_axil_awvalid.value = 0
        if not w_done and int(dut.s_axil_wready.value):
            w_done = True
            dut.s_axil_wvalid.value = 0
        if aw_done and w_done:
            break
    assert aw_done and w_done, f"write to 0x{addr:02x} never handshook"

    for _ in range(timeout_cycles):
        if int(dut.s_axil_bvalid.value):
            resp = int(dut.s_axil_bresp.value)
            await RisingEdge(dut.clk)
            dut.s_axil_bready.value = 0
            return resp
        await RisingEdge(dut.clk)
    raise AssertionError(f"write to 0x{addr:02x} never answered")


async def manual_read(dut, addr, timeout_cycles=64):
    """One AXI4-Lite read beat. Returns (RDATA, RRESP)."""
    dut.s_axil_araddr.value = addr
    dut.s_axil_arvalid.value = 1
    dut.s_axil_rready.value = 1

    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.s_axil_arready.value):
            dut.s_axil_arvalid.value = 0
            break
    else:
        raise AssertionError(f"read of 0x{addr:02x} never handshook")

    for _ in range(timeout_cycles):
        if int(dut.s_axil_rvalid.value):
            data = int(dut.s_axil_rdata.value)
            resp = int(dut.s_axil_rresp.value)
            await RisingEdge(dut.clk)
            dut.s_axil_rready.value = 0
            return data, resp
        await RisingEdge(dut.clk)
    raise AssertionError(f"read of 0x{addr:02x} never answered")

#!/usr/bin/env python3
"""Build and run the cocotbext-axi test suites under Icarus.

Driven from test/Makefile (`make vip`) so that the verification entry point
stays one command regardless of which language a given category is written in.
Invoked directly it takes the module names as arguments:

    .venv/bin/python vip/cocotb/run_vip.py test_axil_protocol
"""

import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

TEST_DIR = Path(__file__).resolve().parents[2]
REPO = TEST_DIR.parent
RTL = REPO / "rtl"

# All suites share one harness and therefore one build.
TOPLEVEL = "vip_axi_top"

SOURCES = [
    RTL / "ultra_sd_pkg.sv",
    RTL / "ultra_sd_reg.sv",
    RTL / "axi4" / "axi4_lite_slave.sv",
    RTL / "axi4" / "async_fifo.sv",
    RTL / "axi4" / "axis_rd_master.sv",
    RTL / "axi4" / "axis_wr_slave.sv",
    RTL / "axi4" / "ultra_sd_axi_top.sv",
    TEST_DIR / "common" / "vip" / "axi4_lite_monitor.sv",
    TEST_DIR / "common" / "vip" / "axis_monitor.sv",
    TEST_DIR / "vip" / "hdl" / "vip_axi_top.sv",
]

ALL_SUITES = ["test_axil_protocol", "test_axis_protocol"]


def main(argv):
    suites = argv[1:] or ALL_SUITES
    build_dir = TEST_DIR / "build" / "vip" / "sim_build"

    runner = get_runner("icarus")
    runner.build(
        verilog_sources=[str(p) for p in SOURCES],
        includes=[str(TEST_DIR / "common")],
        hdl_toplevel=TOPLEVEL,
        build_dir=str(build_dir),
        build_args=["-g2012", "-Wall", "-Wno-timescale"],
        always=True,
    )

    # A .vcd only when asked for: the stream suites move a lot of beats.
    plusargs = ["+dump"] if os.environ.get("DUMP") else []

    results = runner.test(
        hdl_toplevel=TOPLEVEL,
        test_module=suites,
        build_dir=str(build_dir),
        test_dir=str(TEST_DIR / "vip" / "cocotb"),
        results_xml=str(TEST_DIR / "build" / "vip" / "results.xml"),
        plusargs=plusargs,
        extra_env={"PYTHONPATH": str(TEST_DIR / "vip" / "cocotb")},
    )
    print(f"\nresults: {results}")


if __name__ == "__main__":
    sys.exit(main(sys.argv))

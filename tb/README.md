# Testbench

Required by R-DEL-6/R-DEL-7. Depth is up to the author, and its quality is one
of the larger factors in the optionals judgement (Table 14-3).

Must exercise at least:

- the initialisation ladder (Section 6.1 / Appendix B)
- single-block and multi-block read
- single-block and multi-block write
- CRC error injection and recovery
- AXI4-Lite register access, including the SLVERR path

R-DEL-7: the testbench must demonstrably **fail** when the design is broken.
The client injects the faults listed in Appendix E.4 into the RTL and re-runs
it; it must catch them. A behavioural card model that catches injected faults
is worth more, for the optionals pool, than everything else on that list
combined.

Simulator: Icarus Verilog, Verilator or cocotb -- author's choice. cocotb is
permitted and encouraged.

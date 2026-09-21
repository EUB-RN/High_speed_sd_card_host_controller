# Submission checklist (Appendix C)

The first thing the client reads. A checklist that claims something the logs
contradict is worse than an honest gap.

| ✓ | Item | Requirement |
|---|------|-------------|
| ☐ | Five-layer module hierarchy as in Figure 4-1 | R-ARCH-1 |
| ☐ | All Gowin primitives confined to ultra_sd_phy_gowin.sv | R-ARCH-2 |
| ☐ | No module over 400 lines, no procedural block over 120 | R-ARCH-3, R-ARCH-4 |
| ☐ | Zero PLL instances in the core | R-CLK-5, R-RES-5 |
| ☐ | SD clock runtime-adjustable, no hard-coded frequency | R-CLK-2, R-DEG-1 |
| ☐ | Timing report shows positive slack at 50 MHz | R-CLK-6 |
| ☐ | AXI4-Lite: all five channels, SLVERR on unmapped access | R-IF-1, R-IF-2 |
| ☐ | Register map exactly as Table 5-1 | R-IF-2 |
| ☐ | Both AXI4-Stream interfaces compliant, tlast correct | R-IF-5, R-IF-6 |
| ☐ | Survives arbitrary backpressure and producer starvation | R-IF-7, R-IF-8 |
| ☐ | All five statistics counters, counting SD clocks, saturating | R-IF-11 |
| ☐ | Error codes exactly as Table 5-3 | R-IF-12 |
| ☐ | Init ladder in hardware, 74-clock ramp included | R-FUNC-1, R-FUNC-2 |
| ☐ | CMD6 High Speed switch verified by status block read-back | R-FUNC-3 |
| ☐ | SDSC detected and rejected, not silently mishandled | R-FUNC-5 |
| ☐ | 4-bit operation working | R-FUNC-6 |
| ☐ | CMD18/CMD25 multi-block streaming, ACMD23 used | R-FUNC-8, R-FUNC-11 |
| ☐ | CRC16 checked on the fly, four lanes | R-FUNC-9 |
| ☐ | Write CRC status token checked | R-FUNC-13 |
| ☐ | Card detect treated as active low | R-FUNC-14 |
| ☐ | Error recovery without full re-initialisation | R-FUNC-16 |
| ☐ | Every wait bounded by a named timeout | R-FUNC-17 |
| ☐ | All Table 7-1 fallbacks implemented and truthfully reported | R-DEG-5 |
| ☐ | Degradation procedure of Section 7.4 passed, same bitstream | R-DEG-7 |
| ☐ | Verilator lint: zero warnings | R-LANG-9 |
| ☐ | Within all hard resource limits, report attached | R-RES-1, R-RES-2 |
| ☐ | Five clean runs, minimum reported, zero verifier mismatches | R-MEAS-4 |
| ☐ | 30-minute soak, zero unrecovered errors | R-MEAS-5 |
| ☐ | Characterisation table across frequency, reference card | R-MEAS-6 |
| ☐ | README, cdc.md and report.md complete | R-DEL-1 … R-DEL-5 |
| ☐ | Testbench covers the required scenarios | R-DEL-6 |
| ☐ | Testbench catches the Appendix E.4 injected faults | R-DEL-7 |
| ☐ | References cited in the README | R-IP-2 |

**Declared tier:** _state the tier claimed and the minimum-of-five figures that
support it._

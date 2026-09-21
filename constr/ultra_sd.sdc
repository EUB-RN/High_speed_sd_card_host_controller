## ----------------------------------------------------------------------------
## ultra_sd.sdc -- timing constraints (R-CLK-6)
##
## The .cst (physical pin) file is supplied with the kit and must not be edited
## (Section 2.4). This file constrains timing only.
##
## R-CLK-6: the system clock and the derived SD clock shall both be constrained,
## and the Gowin timing report shall show positive slack on all paths with the
## SD clock at 50 MHz. A design that meets a tier only because timing was left
## unconstrained fails.
## ----------------------------------------------------------------------------

# TODO: create_clock for the harness-supplied system clock (SYS_CLK_HZ).
# TODO: create_generated_clock for sd_clk (integer division inside the PHY).
# TODO: constrain SD pad input/output delays; set_false_path / set_max_delay on
#       documented clock-domain crossings (list them in doc/cdc.md, R-CLK-3).

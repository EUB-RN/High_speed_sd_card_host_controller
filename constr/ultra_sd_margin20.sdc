## ultra_sd_margin20.sdc -- the SAME design, constrained 20 % tighter.
##
## WHAT THIS FILE IS FOR
##
## constr/ultra_sd.sdc is the sign-off file: it states the frequencies the
## design actually runs at and the SD interface numbers the specification
## actually requires, and R-CLK-6 is met against it. This file exists to answer
## a different question -- how much room is left before any of that stops being
## true. It constrains every clock in the design 20 % faster and is expected to
## close with positive slack as well; a design that only meets timing at
## exactly its operating point has no margin for a hotter die, a slower part
## within the same speed grade, or the next change somebody makes to it.
##
##   sys_clk       99.000 MHz -> 118.800 MHz   period 10.101 -> 8.417 ns
##   sd_clk_core   49.500 MHz ->  59.400 MHz   period 20.202 -> 16.835 ns
##
## WHY THE SD PADS ARE NOT IN THE 20 %
##
## The margin applies to the fabric, which is what the design controls. It does
## not and cannot apply to the SD pad interface, for two independent reasons:
##
##   1. The pad numbers are not ours. tISU = 6 ns and tODLY = 14 ns are the
##      card's, from SD Physical Layer Simplified Spec v6.00 High Speed. There
##      is no engineering that makes a card need less setup. "20 % margin on
##      tISU" would simply be a different card.
##
##   2. Scaling the pad checks with the clock means clocking the card above
##      50 MHz, and R-DEG-3 is explicit that a design which meets its tier only
##      above 50 MHz fails that tier. The margin run must not quietly ask the
##      board to do the one thing the requirements forbid.
##
## So the pad paths are cut here and ONLY here. They are fully checked in
## ultra_sd.sdc, against the real 49.5 MHz relation and the real spec numbers,
## and that is where their evidence comes from. Cutting them in this file is
## not hiding them; running them at 59.4 MHz would be the dishonest option,
## because it would report a failure the hardware is never asked to survive.
##
## Everything else is identical to ultra_sd.sdc, including the two clocks being
## defined at the same point on the clock network -- see the long note there
## for why that matters more than it looks.

## ---- clocks, 20 % faster ---------------------------------------------------
create_clock -name sys_clk -period 8.417 -waveform {0 4.208} [get_pins {clk_ibuf/O}]
create_generated_clock -name sd_clk_core -source [get_pins {clk_ibuf/O}] -master_clock sys_clk -divide_by 2 [get_pins {u_phy/u_dqce_sd/CLKOUT}]

## ---- SD pads: checked in ultra_sd.sdc, cut here ----------------------------
## Read the header before deleting these four lines.
set_false_path -to   [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3] sd_clk}]
set_false_path -from [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]
set_false_path -from [get_ports {sd_cd}]
set_false_path -to   [get_pins  {*rptr_gray_s1*/D}]
set_false_path -to   [get_pins  {*wptr_gray_s1*/D}]

## The pad output enable is static after reset: u_phy/pad_en_q is 0 under reset,
## 1 one sys_clk later, and never changes again. Same cut as in ultra_sd.sdc,
## same reason.
set_false_path -from [get_pins {*pad_en_q*/Q}]

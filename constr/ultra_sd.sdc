## ultra_sd.sdc -- timing for the CORE as top (syn/build.tcl, or a GUI project
## whose top module is ultra_sd_top). The benchmark bitstream uses
## bench/constr/bench.sdc instead; that one has a PLL in front of clk.
##
## TWO RULES THIS FILE LEARNED THE HARD WAY
##
## 1. Gowin's SDC parser does not support line continuations. A trailing '\'
##    gives "syntax error near token '\'". Every constraint is one line.
##
## 2. Name only PORTS and top-level NETS, never anything below the top module.
##    The Education Edition writes an encrypted netlist, so a path like
##    u_sysctl/u_clk_controller/clk_q[0] is not discoverable after synthesis and
##    Gowin answers ERROR (TA2003) Can't set timing constraint to object.
##    A packed 2-bit clk_q would not survive as clk_q[0] in any case. When one
##    create_generated_clock fails this way, every later constraint that
##    references the clock it would have made fails too (TA2004 Cannot get clock
##    with name ...), which is why one bad object produced ten errors.
##
##    cmd_clk and line_clk ARE addressable: they are nets at the top level of
##    ultra_sd_top, and the tool itself names them in its TA1132 warning.

## ---- system clock ----------------------------------------------------------
## 99 MHz = 27 * 33 / 9, the highest SD-legal rate reachable from the board's
## 27 MHz oscillator. Period 10.101 ns.
create_clock -name sys_clk -period 10.101 -waveform {0 5.050} [get_ports {clk}]

## ---- the two gated clocks the core's logic actually runs on ----------------
## Leave these out and Gowin reports
##   WARN (TA1132) : 'cmd_clk' was determined to be a clock but was not created
## then invents a 100 MHz default, and every crossing between them and sys_clk is
## analysed against a clock at twice the real frequency. That alone manufactured
## 170 ns of total negative slack in the benchmark build.
create_generated_clock -name cmd_clk -source [get_ports {clk}] -master_clock sys_clk -divide_by 2 [get_nets {cmd_clk}]
create_generated_clock -name line_clk -source [get_ports {clk}] -master_clock sys_clk -divide_by 2 [get_nets {line_clk}]

## ---- the clock on the SD pad: 99 / 2 = 49.5 MHz ----------------------------
## Declared on the pad, not on the divider flop inside the PHY. Divide-by-2 is
## the fastest CFG_CLK setting and therefore the worst case for every path here;
## every slower setting only widens the windows.
create_generated_clock -name sd_clk_pad -source [get_ports {clk}] -master_clock sys_clk -divide_by 2 [get_ports {sd_clk}]

## ---- SD pad timing, High Speed 50 MHz 3.3 V --------------------------------
## SD Physical Layer Simplified Spec v6.00 High Speed figures, plus 0.6 ns for
## the dock's ~10 cm of trace each way:
##   tODLY <= 14 ns   card output delay    -> input  max  14.6
##   tOH   >= 2.5 ns  card output hold     -> input  min   1.9
##   tISU  >=  6 ns   setup the card needs -> output max   6.6
##   tIH   >=  2 ns   hold the card needs  -> output min  -2.6
set_input_delay -clock sd_clk_pad -max 14.6 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]
set_input_delay -clock sd_clk_pad -min 1.9 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]
set_output_delay -clock sd_clk_pad -max 6.6 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]
set_output_delay -clock sd_clk_pad -min -2.6 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]

## The PHY does not capture the pads with the SD clock. It detects the pad
## clock's rising edge in the system-clock domain, then counts
## CFG_PHY.SAMPLE_PHASE system clocks before sampling, so the capture edge is
## SAMPLE_PHASE+1 system clocks after the launch edge rather than the next one.
## Without this the tool checks a 10.1 ns window against a 14.6 ns arrival and
## reports a failure the hardware does not have.
set_multicycle_path -setup 2 -from [get_clocks {sd_clk_pad}] -to [get_clocks {sys_clk}]
set_multicycle_path -hold 1 -from [get_clocks {sd_clk_pad}] -to [get_clocks {sys_clk}]

## Clock-object form above does not match: the report still shows a 10.101 ns
## relation on sd_clk_pad -> sys_clk, i.e. required 12.302 against a 14.600
## input delay. State the same intent against the PORTS, which is the form the
## Gowin engine associates with set_input_delay paths.
set_multicycle_path -setup 2 -from [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}] -to [get_clocks {sys_clk}]
set_multicycle_path -hold  1 -from [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}] -to [get_clocks {sys_clk}]


## ---- genuinely asynchronous ------------------------------------------------
## sd_cd is a mechanical contact: unclocked, bouncy for milliseconds, with a
## two-flop synchroniser and a counter debounce behind it. No launch clock
## exists to relate it to, so this is the one input that is correctly cut.
set_false_path -from [get_ports {sd_cd}]

## ---- CDC senkronizatorleri: ilk kademe analiz disi -------------------------
## async_fifo'nun gri pointer'lari iki yonde de iki flop'luk senkronizatorden
## geciyor. cmd_clk sys_clk'in ikiye bolunmusu ve kenarlari cakisik oldugu icin
## arac bu yollari SIFIR pencereli sayiyor ve -2.624 ns raporluyor: hicbir veri
## yolunun karsilayamayacagi bir talep. Gercekte bu bir veri yolu sorusu degil,
## senkronizator zaten metastabilite icin orada.
##
## Kisit DAR tutuldu: yalnizca senkronizatorun BIRINCI kademesinin D girisi.
## cmd_clk ile sys_clk arasina blanket bir false_path atmak, ultra_sd_cmd ile
## blok FSM'i arasindaki GERCEK geciseleri de kontrolden cikarirdi.
## cmd_clk ve line_clk, sys_clk'in ortak kokten ikiye bolunmusu ve kenarlari
## cakisik. Arac bu yuzden cmd_clk -> sys_clk gecislerini SIFIR pencereli
## sayiyor: T aninda launch eden veriyi yine T aninda yakalamasini bekliyor ve
## -2.6 ns raporluyor. Gercek pencere 10.101 ns -- cmd_clk flop'unun cikisi
## T+tco'dan T+20.202+tco'ya kadar kararli, sys_clk onu T+10.101'de yakaliyor,
## yani ~10 ns payla guvenli. Metastabilite yok, senkronizator gerekmiyor.
##
## DOGRU kisit bir saat-saat set_multicycle_path olurdu. Denendi ve bu Gowin
## surumu uygulamadi: -from [get_clocks ...] formu ne duz ne -end ile tutuyor,
## pencere 0.000'da kaliyor (ped multicycle'inda da ayni sorun vardi, orada
## port formu kurtarmisti; saat cifti icin port formu yok).
##
## Bu yuzden yalnizca GERCEK senkronizator girisleri analiz disi birakiliyor --
## async_fifo'nun iki flop'luk gri pointer zincirlerinin birinci kademesi, ki
## false_path orada zaten dogru kisittir. Geriye kalan ~30 cmd_clk -> sys_clk
## yolu BILEREK bastirilmadi: ayni artefakt olduklari teshis edildi, ama
## false_path ile susturmak gercek kapsami da kaybettirir. Bkz. doc/cdc.md.
set_false_path -to [get_pins {*rptr_gray_wr_s1*/D}]
set_false_path -to [get_pins {*wptr_gray_rd_s1*/D}]


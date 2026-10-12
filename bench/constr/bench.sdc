## bench.sdc -- timing for the benchmark bitstream.
##
## Object names here are PORTS and PLL PINS only, never internal nets. The first
## version named the divider flops (u_sd/u_sysctl/u_clk_controller/clk_q[0]) and
## Gowin rejected every one: the Education Edition writes an ENCRYPTED netlist, so
## the post-synthesis name is not discoverable, and a packed 2-bit clk_q would not
## survive as clk_q[0] anyway. Chasing that name is a losing game and it is not
## necessary.
##
## R-CLK-6 asks that the system clock and the derived SD clock both be
## constrained. Both are reachable without naming anything internal: the system
## clock at the PLL output, the SD clock at the pad it leaves through. Declaring it
## on the pad is also the more honest statement -- "the clock the card sees is
## sys_clk/2" is exactly the relationship the pad timing below is measured against.
##
## The gated clock inside the core (sd_clk_core) is left for Gowin to
## propagate through the DQCE and DCS primitives, which it does. Check the timing
## report lists them: propagated automatically is as good as declared, silently
## absent is not.

## ---- board oscillator ------------------------------------------------------
create_clock -name clk27 -period 37.037 -waveform {0 18.518} [get_ports {clk27}]

## ---- system clock: 27 * 33 / 9 = 99 MHz ------------------------------------
create_generated_clock -name sys_clk -source [get_ports {clk27}] -master_clock clk27 -multiply_by 33 -divide_by 9 [get_pins {u_pll/CLKOUT}]

## ---- the two gated clocks the core's logic actually runs on ----------------
## These MUST be declared. Left out, Gowin reports
##   WARN (TA1132) : 'u_sd/sd_clk_core' was determined to be a clock but was not created
## and then invents a 100 MHz default for them. Everything that crosses between
## them and sys_clk is then analysed against a clock that is twice the real
## frequency, which produced a 170 ns total negative slack made almost entirely of
## nothing: the worst path had a 2.27 ns data delay and -15.47 ns of slack.
##
## The warning is also where the names come from. These two are top-level nets in
## ultra_sd_top, not optimised-away internals, so unlike the divider flops they
## survive synthesis under a name the tool will match.
create_generated_clock -name sd_clk_core -source [get_pins {u_pll/CLKOUT}] -master_clock sys_clk -divide_by 2 [get_pins {u_sd/u_phy/u_dqce_sd/CLKOUT}]

## ---- the clock on the SD pad: 99 / 2 = 49.5 MHz ----------------------------
## Divide-by-2 is the fastest CFG_CLK setting and so the worst case for every
## path in the design; every slower setting only lengthens the windows.
## (pad clock = core clock: tek net, tek saat objesi -- bkz. constr/ultra_sd.sdc)

## ---- SD pad timing, High Speed 50 MHz 3.3 V -------------------------------
## SD Physical Layer Simplified Spec v6.00 High Speed figures, plus 0.6 ns for
## the dock's ~10 cm of trace each way:
##   tODLY <= 14 ns   card output delay      -> input  max  14.6
##   tOH   >= 2.5 ns  card output hold       -> input  min   1.9
##   tISU  >=  6 ns   setup the card needs   -> output max   6.6
##   tIH   >=  2 ns   hold the card needs    -> output min  -1.4
## Cikis tarafindaki ortak-mod kredisinin gerekcesi, -min'in isaret turetmesi
## ve kredinin setup/hold'da neden TERS yone yuvarlandigi constr/ultra_sd.sdc'de.
##   -max =  (iz + tISU) - 5.0  =  1.6
##   -min = -(tIH - iz)  - 6.0  = -7.4
set_input_delay -clock sd_clk_core -max 14.6 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]
set_input_delay -clock sd_clk_core -min 1.9 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]

set_output_delay -clock sd_clk_core -max 1.6 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]
set_output_delay -clock sd_clk_core -min -7.4 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]

## THE SAMPLING WINDOW NEEDS A MULTICYCLE
##
## The PHY does not capture the pads with the SD clock. It detects the pad clock's
## rising edge in the system-clock domain, then counts CFG_PHY.SAMPLE_PHASE system
## clocks before sampling. The capture edge is therefore SAMPLE_PHASE+1 system
## clocks after the launch edge, not the next one, and without saying so the tool
## checks a 10.1 ns window against a 14.6 ns arrival and reports a failure the
## hardware does not have.
##
## At divide-by-2 one SD period is exactly two system clocks, so there are exactly
## TWO sampling phases available (R-DEL-1 asks for this number): 10.1 ns and
## 20.2 ns after the launch edge. The valid window on the pad is
## [tODLY, next edge + tOH] = [14.6, 22.1] ns, so phase 0 misses it and phase 1
## sits inside with roughly 5 ns either side. The benchmark does not take that on
## trust -- it scans the phases and keeps the first that verifies -- but phase 1 is
## what the numbers above assume.
set_multicycle_path -setup 2 -from [get_clocks {sd_clk_core}] -to [get_clocks {sys_clk}]
set_multicycle_path -hold  1 -from [get_clocks {sd_clk_core}] -to [get_clocks {sys_clk}]

## Clock-object form above does not match: the report still shows a 10.101 ns
## relation on sd_clk_core -> sys_clk, i.e. required 12.302 against a 14.600
## input delay. State the same intent against the PORTS, which is the form the
## Gowin engine associates with set_input_delay paths.
set_multicycle_path -setup 2 -from [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}] -to [get_clocks {sys_clk}]
set_multicycle_path -hold  1 -from [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}] -to [get_clocks {sys_clk}]


## ---- genuinely asynchronous, and don't-cares -------------------------------
## sd_cd is a mechanical contact: unclocked, bouncy for milliseconds, with a
## two-flop synchroniser and a counter debounce behind it. There is no launch
## clock to relate it to, so this is the one input that is correctly cut.
set_false_path -from [get_ports {sd_cd}]

## ---- CDC senkronizatorleri: ilk kademe analiz disi -------------------------
## async_fifo'nun gri pointer'lari iki yonde de iki flop'luk senkronizatorden
## geciyor. sd_clk_core sys_clk'in ikiye bolunmusu ve kenarlari cakisik oldugu icin
## arac bu yollari SIFIR pencereli sayiyor ve -2.624 ns raporluyor: hicbir veri
## yolunun karsilayamayacagi bir talep. Gercekte bu bir veri yolu sorusu degil,
## senkronizator zaten metastabilite icin orada.
##
## Kisit DAR tutuldu: yalnizca senkronizatorun BIRINCI kademesinin D girisi.
## sd_clk_core ile sys_clk arasina blanket bir false_path atmak, ultra_sd_cmd ile
## blok FSM'i arasindaki GERCEK geciseleri de kontrolden cikarirdi.
## sd_clk_core, sys_clk'in ortak kokten ikiye bolunmusu ve kenarlari
## cakisik. Arac bu yuzden sd_clk_core -> sys_clk gecislerini SIFIR pencereli
## sayiyor: T aninda launch eden veriyi yine T aninda yakalamasini bekliyor ve
## -2.6 ns raporluyor. Gercek pencere 10.101 ns -- SD saati flop'unun cikisi
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
## false_path orada zaten dogru kisittir. Geriye kalan ~30 sd_clk_core -> sys_clk
## yolu BILEREK bastirilmadi: ayni artefakt olduklari teshis edildi, ama
## false_path ile susturmak gercek kapsami da kaybettirir. Bkz. doc/cdc.md.
set_false_path -to [get_pins {*rptr_gray_s1*/D}]
set_false_path -to [get_pins {*wptr_gray_s1*/D}]


## The UART and the LEDs are the report, not the measurement: one drives a 115200
## baud line, the other a human eye. Nothing about the tier depends on them.
set_false_path -to [get_ports {uart_tx led[0] led[1] led[2] led[3]}]

## ---- ped cikis enable'i: reset sonrasi SABIT -------------------------------
## u_phy/pad_en_q reset altinda 0, birakildiktan bir sys_clk sonra 1 ve bir daha
## asla degismez; IOBUF'larin OEN'ini yalnizca "pedler henuz acilmadi" diye
## maskeler. Per-cevrim OE sinyali cmd_oe_i / dat_oe_i'dir ve o SD saatinde
## surulur, ayrica analiz edilir ve payla geciyor.
##
## Bu kisit, iki saat tek saate indirildiginde ORTAYA CIKTI. Onceki surumde ped
## cikis gecikmeleri 'sd_clk_pad' adli, ped portuna tanimlanmis ama fabric'te
## hicbir yolu olmayan bir saate baglanmisti; STA raporu bunu acikca soyluyordu:
##   "No timing paths to get frequency of sd_clk_pad!"
## Yani SD ped cikis zamanlamasi HIC kontrol edilmiyordu, TNS 0 gorunmesinin
## sebebi de buydu. Ayni net artik tek bir saat objesi tasidigi icin kontroller
## gercekten kosuyor; geriye kalan tek "ihlal" bu statik enable.
set_false_path -from [get_pins {*pad_en_q*/Q}]

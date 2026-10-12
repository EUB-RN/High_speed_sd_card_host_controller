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
##    sd_clk_core IS addressable: it is a net at the top level of ultra_sd_top,
##    and the tool itself names it in its TA1132 warning.

## ---- system clock ----------------------------------------------------------
## 99 MHz = 27 * 33 / 9, the highest SD-legal rate reachable from the board's
## 27 MHz oscillator. Period 10.101 ns.
##
## 3. DEFINE BOTH CLOCKS AT THE SAME POINT ON THE CLOCK PATH, OR STA LIES BY
##    SEVERAL NANOSECONDS IN BOTH DIRECTIONS.
##
## This used to read [get_ports {clk}]. That is the textbook place for a base
## clock and it is wrong here, because of how this tool treats a generated
## clock: it starts the generated clock AT ITS DEFINITION POINT with zero
## latency and does not propagate the source's insertion delay to it. The
## evidence is in the path dumps -- for a sys_clk launch the clock path reads
##     tCL 0.000 -> clk_ibuf/I ; tINS 4.230 -> clk_ibuf/O ; tNET 2.271 -> flop
## (6.501 ns of insertion) while the sd_clk_core side of the same report reads
##     tCL 0.000 -> u_phy/u_dqce_sd/CLKOUT ; tNET 2.270 -> flop
## (2.270 ns). Both clocks physically come down the same global network from
## the same pad, so that 4.231 ns is not skew -- it is an unmodelled constant.
##
## What it cost: 87 endpoints reported as hold violations on sd_clk_core ->
## sys_clk, worst -2.268 ns, every one of them with the identical -3.128 skew
## that gives the artefact away. Those are the cdc.md rows 10-12 crossings, the
## ones that document themselves as divided-clock synchronous paths. They were
## never unsafe; the launch clock was simply modelled 4.2 ns early.
##
## Three fixes were measured before this one was kept:
##   a) set_clock_latency -source <n> on sd_clk_core. The command IS accepted
##      by this version, contrary to the note further down that said it does
##      not exist. With a single value it cannot work: the right number is the
##      ibuf delay, which is 4.230 ns in the slow model and 1.392 in the fast
##      one, so one value fixes setup and breaks hold or the other way round
##      (measured: 4.231 gave 4 setup / 68 hold; 6.501 gave 9 / 345).
##   b) the same with -early 1.392 / -late 4.230. Hold went to zero, and the
##      SD pad outputs went to -2.640: a pad check launches and captures on
##      the SAME clock, so the tool took the late value on the launch side and
##      the early one on the capture side and charged the path 2.84 ns that
##      does not exist.
##   c) sourcing the generated clock at clk_ibuf/O while sys_clk stayed on the
##      port. Rejected: -master_clock then cannot resolve (TA2004), and
##      without -master_clock the tool will not create the clock at all.
##
## Defining BOTH at clk_ibuf/O removes the asymmetry instead of compensating
## for it, so it needs no tuned constant and cannot drift when the device,
## the corner or the placement changes. Result: 0 setup and 0 hold violated
## endpoints, worst setup +0.274 ns, worst hold +0.225 ns.
##
## What is given up is timing on the clk port itself -- the report now says
## "No timing paths to get frequency of clk!". Nothing is lost by that: the
## only I/O timing in this design is on the SD pads and those are referenced
## to sd_clk_core, and R-CLK-6 asks for the system clock to be constrained,
## which it is -- one buffer downstream of the pin it enters on.
create_clock -name sys_clk -period 10.101 -waveform {0 5.050} [get_pins {clk_ibuf/O}]

## ---- the gated clock the core's logic actually runs on ---------------------
## Leave this out and Gowin reports
##   WARN (TA1132) : 'sd_clk_core' was determined to be a clock but was not created
## then invents a 100 MHz default, and every crossing between it and sys_clk is
## analysed against a clock at twice the real frequency. That alone manufactured
## 170 ns of total negative slack in the benchmark build.
##
## There used to be two of these, cmd_clk and line_clk, declared separately
## because the PHY built two gated copies of one divider and a DCS chose between
## them for the pad. The select bit was tied off and both enables were the same
## wire, so the second copy was dead logic that cost a global clock network and
## made every L1 <-> L3 path an inter-clock path for STA. One clock now.
## -source is clk_ibuf/O and not the clk port, for the reason written out at
## length above the sys_clk definition: both clocks have to start at the same
## point on the same physical network or the tool invents 4.2 ns of skew.
create_generated_clock -name sd_clk_core -source [get_pins {clk_ibuf/O}] -master_clock sys_clk -divide_by 2 [get_pins {u_phy/u_dqce_sd/CLKOUT}]

## ---- the clock on the SD pad ----------------------------------------------
## There is no separate pad clock any more, and that is the point: the DQCE
## output above drives the pad AND the core, one net, one clock object. A second
## create_generated_clock on [get_ports {sd_clk}] now fails (the net already
## carries sd_clk_core) and takes every constraint that references it with it.
## So the pad constraints below use sd_clk_core; STA walks the net delay out to
## the pad on its own. Divide-by-2 is the fastest CFG_CLK setting and therefore
## the worst case for every path here; every slower setting only widens the
## windows.

## ---- SD pad timing, High Speed 50 MHz 3.3 V --------------------------------
## SD Physical Layer Simplified Spec v6.00 High Speed figures, plus 0.6 ns for
## the dock's ~10 cm of trace each way:
##   tODLY <= 14 ns   card output delay    -> input  max  14.6
##   tOH   >= 2.5 ns  card output hold     -> input  min   1.9
##   tISU  >=  6 ns   setup the card needs -> output max   6.6
##   tIH   >=  2 ns   hold the card needs  -> output min  -1.4
##
## ---- ped saatinin ORTAK-MOD payi (elle modellendi) -------------------------
## Kart, saatini de verisini de AYNI yollardan gectikten sonra karsilastirir.
## STA bunu modelleyemiyor: bu araca gore ped portu ile DQCE cikisi TEK nesne
## ("clock sd_clk_pad is ignored because Object 'sd_clk_d' already has one
## clock applied on it"), yani saatin pede kadarki yolculugunu tanimlayacak
## ikinci bir saat objesi yaratilamiyor. Sonuc, P&R raporunun kendi
## dokumunde acikca gorulur (bench build, LVCMOS33, gercek pinler):
##
##   Data Arrival Path          Required Clock Path Delay: cell 0.000 route 0.000
##     +2.270  tNET   saat agaci -> flop             <-- ORTAK MOD
##     +0.232  tC2Q   flop cikisi                        gercek fark
##     +1.062  tNET   fabric -> ped girisi               gercek fark
##     +3.684  tINS   ped surucusu -> bacak          <-- ORTAK MOD
##
## Launch tarafina 2.270 + 3.684 = 5.954 ns yaziliyor, capture tarafina SIFIR.
## Oysa kartin CLK pinine gelen saat de ayni global agdan ve ayni sinif bir
## cikis pedinden geciyor. Saat ile veri arasinda GERCEKTEN fark yaratan tek
## terim tC2Q + fabric route = 1.294 ns.
##
## Pay olarak 5.954 yerine 5.0 ns krediliyoruz: aradaki ~0.95 ns, global agin
## iki ucu (veri flopu ve saat pedi) arasindaki skew ile IOBUF/OBUF hucre
## farki icin birakilan emniyet payi. Kredi output delay'e tasiniyor, cunku
## bu araçta tek knob o:
##   -max : 6.6 - 5.0  =  1.6   (tISU 6 ns + 0.6 iz, 5.0 ortak-mod kredisi)
##   -min : -(1.4 + 6.0) = -7.4  (asagidaki isaret turetmesi)
## Kredi geri alinmak istenirse 6.6 / -1.4 degerlerine donmek yeterli; o hal
## setup'ta guvenli ama ~5 ns pesimist ve donanimda olculen davranisla
## celisiyor (49.5 MHz'de sifir mismatch, bkz. reports/bench_live_final.txt).
## Hold'da ise kredisiz hal GUVENLI DEGILDIR, asagi bak.
##
## ---- -min'in ISARETI: aracin kendi dokumunden dogrulandi ------------------
## Gowin'in required-time formulu TOPLAMA degil CIKARMA. Setup Paths Table
## Path1'in dokumu (syn/core_pnr/impl/pnr/project_tr_content.html):
##     Data Required Path:   AT      DELAY   TYPE
##                        20.202    20.202   active clock edge time
##                        18.602    -1.600   tOut
## yani  required = capture kenari - output_delay. Ayni isaret hold tarafinda da
## gecerli: required_hold = hold kenari - output_delay_min. BUNUN SONUCU:
## -min NE KADAR POZITIFSE HOLD O KADAR GEVSER.
##
## Dosyanin eski degeri +2.4 idi. Bu, hold'a 2.4 ns BEDAVA pay veriyordu, yani
## kisit niyetin (hold'u zorlastirmak) TAM TERSI yonde yanlisti; ped cikis
## hold'u pratikte hic kontrol edilmiyordu. Sanal dis flop modeli:
##     -max =  (iz + tISU) - kredi_setup
##     -min = -(tIH - iz)  - kredi_hold
## Kredisiz standart hal -min = iz - tIH = 0.6 - 2.0 = -1.4 olur.
##
## AMA kredisiz -min hold icin ANTI-KONSERVATIFTIR. STA saatin pede kadarki
## yolculugunu (agac 2.270 + ped 3.684 = 5.954) VERI tarafina yaziyor, capture
## tarafina sifir yaziyor. Hold'da bu farki krediLEMEMEK, arrival'a bedava
## 5.954 ns eklemek demektir; -1.4 ile her ped cikisi otomatik gecer.
##
## Bu yuzden ayni kredi iki checkte TERS yone yuvarlanir -- tek dogru pesimizm
## budur:
##     setup: kredi KUCUK sayilir -> 5.0   (olculen 5.954'un altinda)
##     hold : kredi BUYUK sayilir -> 6.0   (olculen 5.954'un ustunde)
## Aradaki 1.0 ns bant, global agin iki ucu (veri flopu leaf'i ile saat pedi
## leaf'i) arasindaki skew ve IOBUF/OBUF hucre farki icin.
##     -min = -(2.0 - 0.6) - 6.0 = -7.4
##
## Bu degerle hold checki fiziksel soruya indirgenir: ped cikisindaki veri,
## kartin CLK pinine gelen kenardan en az tIH kadar SONRA degismeli. Kredi
## sadelestirildiginde kalan sart
##     tC2Q + fabric route + (ped_veri - ped_saat)  >=  tIH - iz = 1.4 ns
## olur; ortak-mod terimleri (saat agaci, ayni sinif ped) sadelesir.
##
## Bu kisit BUGUN hicbir hold yolunu baglamiyor: veri DUSEN kenarda suruluyor,
## yani hold tarafinda yarim periyotluk (10.101 ns) fazladan pay var. Ancak TX
## launch'i YUKSELEN kenara almak gundeme gelirse launch ile ornekleme kenari
## cakisir ve hold dogrudan tIH'e dayanir -- o semanin marj analizi ve neden
## tutmadigi: doc/tx_launch_edge.md.
## ---- PED SAATINI SAAT OBJESI YAPMA: IKI DENEME, IKISI DE OLDU -------------
## Yukaridaki elle kredi cirkin; dogrusu saatin pede kadarki yolculugunu STA'nin
## CAPTURE tarafina koymak olurdu. Iki yol da denendi ve OLCULDU (2026-10-08,
## syn/core_pnr). Tekrar denemeyin:
##
## 1) create_generated_clock ... -add [get_ports {sd_clk}]
##    Bu surum -add'i KABUL EDIYOR. Yukarideki "ikinci saat objesi yaratilamiyor"
##    notu bu yonuyle YANLIS: sd_clk_pad gercekten yaratiliyor, Fmax tablosunda
##    ve capture saati olarak goruluyor. AMA hicbir ise yaramiyor, cunku Gowin
##    uretilmis saati TANIM NOKTASINDA gecikmesiz kabul ediyor; kaynak -> ped
##    yolunu capture tarafina tasimiyor. Yol dokumu, sd_clk_pad capture iken:
##        Required Clock Path Delay   cell: 0.000, 0.000%; route: 0.000, 0.000%
##    Yani kredi kalkiyor, karsiliginda sifir geliyor: slack -0.222 -> -5.430.
##
## 2) create_clock -waveform {6.852 16.953} [get_ports {sd_clk}] -add
##    Saatin gec geldigini dalga seklini kaydirarak soylemek. Rapor guzellesiyor
##    (sd_clk_core Fmax 48.4 -> 63.1, TNS 0.000) ama bu SAHTE: ped cikis
##    kontrolleri TAMAMEN KAYBOLUYOR. Olculen imza:
##        tOut yolu sayisi   5 -> 0
##        'dat_out_q' raporda 16 kez -> 0 kez
##        "No timing paths to get frequency of sd_clk_pad!" geri geliyor
##    Yani port bir saat objesi tasidigi anda arac o porta giden veri yollarini
##    analiz etmeyi birakiyor -- asagida 'ped cikis enable'i' basliginda anlatilan
##    tarihi felaketin ta kendisi. ASLA.
##
## 3) set_clock_latency: VAR, bu not yanlisti. Komut kabul ediliyor ve etki
##    ediyor; olculen sonuclari sys_clk tanimininin ustundeki (a) ve (b)
##    maddelerinde. Ped kredisinin yerine GECMIYOR: ped checki ayni saatle
##    launch ve capture ettigi icin tek degerli latency sadelesir, -early /
##    -late ise kendi icinde 2.84 ns'lik sahte bir fark yaratir.
##
## SONUC: elle kredi bir tercih degil, tek mekanizma. Buyuklugu olculen
## (saat agaci + cikis buffer) degerine baglanmali, ve setup/hold'da ters yone
## yuvarlanmali -- yukari bak.
##
## UYARI (ayri is): bench build'inde ped cikis yollari ZATEN analiz edilmiyor.
## bench/impl/pnr raporunda tOut yolu 0, 'dat_out_q' 0 kez geciyor; giris
## yollari ise analiz ediliyor. Yukaridaki (2) ile ayni imza, sebebi
## bulunmadi. Yani bench'in temiz sd_clk_core tablosu ped cikis kontrolunu
## ICERMIYOR; gercek kontrolu yapan tek build syn/core_pnr.

set_input_delay -clock sd_clk_core -max 14.6 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]
set_input_delay -clock sd_clk_core -min 1.9 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]
set_output_delay -clock sd_clk_core -max 1.6 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]
set_output_delay -clock sd_clk_core -min -7.4 [get_ports {sd_cmd sd_dat[0] sd_dat[1] sd_dat[2] sd_dat[3]}]

## The PHY does not capture the pads with the SD clock. It detects the pad
## clock's rising edge in the system-clock domain, then counts
## CFG_PHY.SAMPLE_PHASE system clocks before sampling, so the capture edge is
## SAMPLE_PHASE+1 system clocks after the launch edge rather than the next one.
## Without this the tool checks a 10.1 ns window against a 14.6 ns arrival and
## reports a failure the hardware does not have.
set_multicycle_path -setup 2 -from [get_clocks {sd_clk_core}] -to [get_clocks {sys_clk}]
set_multicycle_path -hold 1 -from [get_clocks {sd_clk_core}] -to [get_clocks {sys_clk}]

## Clock-object form above does not match: the report still shows a 10.101 ns
## relation on sd_clk_core -> sys_clk, i.e. required 12.302 against a 14.600
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

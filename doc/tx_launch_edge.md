# TX launch kenari: dusen -> yukselen gecisi neden BEKLETILDI

Durum: **uygulanmadi.** Karar, asagidaki hold analizinin mevcut veriyle
kapatilamamasina dayaniyor. RTL'de launch kenari DEGISMEDI; bu revizyonda
yalnizca `set_output_delay -min` isaret hatasi duzeltildi (bkz. en alt).

## 0. MARJ: F->R semasi %20-25'i ASLA tutamaz

Bu bolum sonradan eklendi; onceki "once (c)" onerisini GECERSIZ kiliyor.

Model, senin verdigin tek slack sayisindan kuruldu ve raporun Fmax'ini aynen
uretiyor -- yani guvenilir:

    F->R semasinda  Fmax = 1000 / (2 * (OD_max + D))
    D = 10.101 - 6.6 - (-0.222) = 3.723 ns
    Fmax = 1000 / (2 * 10.323) = 48.44 MHz     (rapor: 48.4)  <-- model dogru

`OD_max = 6.6 ns` SPEC'TEN SABIT (tISU 6.0 + iz 0.6). Ped gecikmesi 3.68 ns
ve tC2Q 0.23 ns indirilemez. Dolayisiyla F->R semasinin TAVANI var:

| Sema | D (ns) | Fmax (MHz) | 49.5'te marj |
|---|---|---|---|
| F->R bugun | 3.72 | 48.4 | **-2.2%** |
| F->R + IOB | 2.66 | 54.0 | **+9.0%** |
| F->R + IOB + ideal saat agaci | 2.41 | 55.5 | **+12.1%** |
| **R->R bugun** | 3.72 | **96.9** | **+95.7%** |
| R->R + IOB | 2.66 | 108.0 | +118.1% |

Gereken: %20 icin 59.4 MHz, %25 icin 61.9 MHz.
**Ikisi de F->R tavaninin (54-55 MHz) UZERINDE.**

Sebebi aritmetik: yarim periyot 49.5 MHz'te 10.101 ns, ama spec'in istedigi
setup arti pedin kendisi zaten

    6.6 + 3.68 + 0.23 = 10.51 ns  >  10.101 ns

Yani yarim periyot semasi 50 MHz'te YAPISAL olarak butce disinda. Bugunku
tasarim 48.4 MHz'e ancak saat agaci kredisinin (1.247 ns) tamamini yiyerek
ulasiyor; marji hic olamaz. Bu bir ayar sorunu degil.

**SD spec'inin HS'te launch'i yukselen kenara almasinin sebebi tam olarak
budur.** Yani istedigin marj, gorevin basinda istedigin degisikligi ZORUNLU
kiliyor: tek yol R->R.

### Bunun hold'a etkisi
R->R'de hold FREKANSTAN BAGIMSIZ (launch ve yakalama ayni kenar), yani
96.9 MHz'lik setup payindan hic faydalanmaz. Yapisal olarak cozulmek zorunda.
Iyi haber: gecerli pencere `1.4 <= D_eff <= 13.602` ns, yani 12.2 ns genis.
D_eff_min ~1.30-2.23 araliginda ve tek eksigi 1.4 ns tabanini gecmek; ped
saatini 0.5-1 ns kadar one almak yetiyor. Yarim periyotluk dev bir kayma
gerekmiyor.

Ve dikkat: R->R semasinda **(c) ZARARLI** -- route'un 1.06 ns'i hold'un lehine
calisiyor, IOB onu silip D_eff_min'i 1.4'un altina iter. (c) yalnizca
(b) ile BIRLIKTE anlamli.

### Revize oneri
1. **R->R launch** (bu dokumanin sec. 5'i) -- marj icin baska yol yok.
2. **Ped saatine kucuk faz ilerlemesi** (bench'te PLL zaten var) -- hold'u
   yapisal olarak kapatir, olcumun insafina birakmaz.
3. **IOB'ye DOKUNMA** -- 1.06 ns route hold'un yastigi.
4. (a) ve tek basina (c) elendi: (a) bandwidth'in yarisini oder, (c) %9'da
   tavan yapar.

## 1. Soru

Bugun TX verisi SD saatinin DUSEN kenarinda suruluyor, kart YUKSELEN kenarda
ornekliyor. Setup butcesi yarim periyot (49.5 MHz'de 10.101 ns). Launch'i
yukselen kenara alirsak butce tam periyot (20.202 ns) olur. SD spec'inin High
Speed konvansiyonu da budur.

Bedeli hold tarafinda. Bu dokumanin tamami o bedelin ne oldugu sorusudur.

## 2. Hold esitsizliginin YONU

Kaynak-senkron bir cikista, kart saatinin kendi yukselen kenarini referans
alarak:

    D_eff  =  (verinin kart pinine varis gecikmesi)
          - (saatin kart pinine varis gecikmesi)

Kart, veriyi kendi kenarindan **tIH = 2 ns** sonrasina kadar kararli istiyor.
Launch ve ornekleme AYNI kenar tipinde oldugunda (yukselen launch), bir sonraki
bit kendi launch kenarinda cikar ve ayni kenarda yakalanan biti bozabilir.
Kosul:

    hold:   D_eff  >=  tIH  =  2 ns
    setup:  D_eff  <=  T - tISU  =  20.202 - 6 = 14.202 ns

Yani **hold, D_eff'in BUYUK olmasini ister.** Veri yolu ne kadar YAVASsa hold o
kadar rahattir.

Gorev tanimindaki "1.3 ns < 2 ns, yani hold 0.7 ns acik kalabilir" okumasi bu
esitsizligi ters cevirmis. Dogru okuma: 1.3 ns, istenen 2 ns'in ALTINDA, yani
hold **0.7 ns ACIKTA KALIYOR** (ihlal).

Bunun bagimsiz teyidi gorev tanimindaki (c) secenegidir: "cikis flop'larini
IOB'ye almak fabric route 1.06 ns'i yoldan cikarir, ama hold'u DAHA da sikar."
Bu cumle ancak hold'un COK veri gecikmesi istemesi halinde dogrudur -- yani
(c)'nin gerekcesi dogru, basliktaki karsilastirma ise ters. Ikisi ayni anda
dogru olamaz.

## 3. Araca gore sayilar

Rapordaki tek olcumden geriye dogru calisiyoruz. Bugunku F->R sinifi:
pencere 10.101 ns, en kotu slack -0.222 ns, `set_output_delay -max` 6.6 ns.

    slack_setup = W - OD_max - D
    -0.222      = 10.101 - 6.6 - D      =>   D_max = 3.723 ns

`D_max`, aracin yavas (max) koseden gordugu etkin veri-saat kaymasi. Bu
rapora DAYANAN tek saglam sayi; tC2Q 0.23 / route 1.06 / ped 3.68 dokumu bunun
bilesenleridir ve ped'in ne kadarinin saatle ortak-mod sadelestigi raporun
kendi hold dokumunden okunmak zorunda.

### Setup

| Sema | W (ns) | OD_max | D_max | slack (ns) |
|---|---|---|---|---|
| Bugun: F -> R | 10.101 | 6.6 | 3.723 | **-0.222** |
| Onerilen: R -> R | 20.202 | 6.6 | 3.723 | **+9.879** |
| (a) div 4, F -> R | 20.202 | 6.6 | 3.723 | **+9.879** |
| (c) IOB, F -> R | 10.101 | 6.6 | ~2.66 | **~+0.84** |

Setup tarafinda onerilen degisiklik gercekten calisiyor: `sd_clk_core:[F] ->
sd_clk_core:[R]` sinifi kayboluyor, yerine ~9.9 ns payli bir R -> R sinifi
geliyor.

### Hold

Hold iliskisi, F->R semasinda launch kenarindan yarim periyot GERIDEKI
yakalama kenaridir; R->R semasinda AYNI kenardir. Duzeltilmis
`OD_min = -1.4` ile:

| Sema | hold iliskisi (ns) | slack (ns) |
|---|---|---|
| Bugun: F -> R | +10.101 | D_min + 8.701  -> her zaman cok genis |
| Onerilen: R -> R | 0 | **D_min - 1.4  -> isareti BILINMIYOR** |
| (a) div 4, F -> R | +20.202 | D_min + 18.802 -> her zaman cok genis |
| (c) IOB, F -> R | +10.101 | D_min' + 8.701 -> hala cok genis |

`D_min`, HIZLI kosedeki deger. Setup raporundan TURETILEMEZ. Gowin'in hizli
modeli tipik olarak yavas kosenin 0.35--0.6 kati:

| D_min / D_max | D_min (ns) | R->R hold slack (ns) |
|---|---|---|
| 0.60 | 2.23 | +0.83 |
| 0.50 | 1.86 | +0.46 |
| 0.40 | 1.49 | +0.09 |
| 0.35 | 1.30 | **-0.10** |

Yani duzeltilmis kisitla bile sonuc **-0.1 ile +0.8 ns arasinda**: tam olarak
tahminin degil, gercek raporun okunmasi gereken bolge.

Gorev tanimindaki fiziksel model (ped tamamen ortak-mod kabul edilip
D = tC2Q 0.23 + route 1.06 = 1.29 ns alinirsa) ise yavas kosede dahi
1.29 < 2.0, yani **-0.71 ns ile ihlal**; hizli kosede daha kotu. Iki model
arasindaki fark (3.723'e karsi 1.29) tamamen ped gecikmesinin saatle ne kadar
sadelestigi sorusudur ve bunu yalnizca "Hold Paths Table" soyler.

## 4. KARAR

Uc bagimsiz isaret de ayni yone bakiyor:

1. Gorev tanimindaki fiziksel hesap, YONU duzeltildiginde 0.71 ns ihlal veriyor.
2. Hold hizli koseden olculur; 1.29 / 3.723 yavas-kose sayilarindan kucuktur.
3. (c) secenegine dair kendi gerekcesi, tasarimin hold icin yanlis tarafta
   oldugunu teyit ediyor.

Araca gore en iyimser senaryoda bile pay +0.8 ns, en kotude -0.1 ns. Bir
cikis hold ihlali P&R'da degil SAHADA, sicaklikla gelip giden veri bozulmasi
olarak ortaya cikar; yarim periyotluk guvenli bir calisan tasarimi 0.1 ns'lik
belirsizlige takas etmek dogru degil.

**Launch kenari degistirilmedi.** Kapiyi acan olcum tek bir calistirmadir:

    cd syn/core_pnr && QT_QPA_PLATFORM=offscreen \
      LD_LIBRARY_PATH=$HOME/Downloads/IDE/lib ~/Downloads/IDE/bin/gw_sh build.tcl

ve `impl/pnr/project_tr_content.html` icinde **"Hold Paths Table"**: oradaki
`u_cmd/cmd_out_q` ve `u_line/dat_out_q[*]` -> ped yollarinin veri varis ve saat
varis dokumunden `D_min` dogrudan okunur. `D_min >= 1.4 ns` ise degisiklik
guvenle uygulanabilir.

## 5. Uygulanacaksa: degisikligin tam kapsami

Analiz yapildi, kodlanmadi. Iki negedge blogu posedge'e alinir:
`rtl/ultra_sd_cmd.sv` (cmd_out_q, cmd_oe_q, tx_sh_q, tx_cnt_q, tx_active_q,
tx_done_q, tx_crc_fold_q) ve `rtl/ultra_sd_line.sv` (dat_out_q, dat_oe_q,
tx_sh_q). `rtl/ultra_sd_phy_gowin.sv` icindeki negedge DQCE modeli
SIMULASYON icindir, dokunulmaz.

Uc hiza bir kademe one cekilir:

1. **tx_go_q el sikismasi.** FSM `tx_go_q`'yu posedge n'de (C_LOAD) kurar;
   blok da posedge'e alininca ayni kenarda ESKI degeri okur ve bir cevrim
   geriden yuklenir. Yuk tetigi `tx_go_q` yerine `state_q == C_LOAD` olmali
   ki yuk posedge n'de olsun. C_LOAD tek cevrimlik ve kosulsuz C_TX'e
   gectigi icin tetik kendiliginden tek atimlik.

2. **CRC7 beslemesi.** `crc_bit = tx_crc_fold_q ? cmd_out_q : cmd_in_i` ve
   `crc_q` posedge'de katlaniyor. Yuk 1. maddedeki gibi bir kademe one
   cekildiginde hiza KENDILIGINDEN korunur: NBA semantigi geregi posedge'deki
   katlama `cmd_out_q`'nun kenar-oncesi degerini gorur, yani her iki semada da
   "hatta o an duran bit" katlanir. Ek olarak bu ic yol da yarim cevrimden tam
   cevrime cikar, yani RAHATLAR.

3. **`ultra_sd_line` kaydirici hizasi.** `tx_take_o`, `tx_drive`, `tx_grp`,
   `cell_q` hepsi posedge alanindadir ve negedge blogu bunlari kombinasyonel
   okuyor. Blok posedge'e alininca `cell_q`'yu bir cevrim geriden gorur;
   yukleme/kaydirma kolu buna gore bir kademe one cekilmeli
   (`tx_take_o` CELL_ARM'da da yukseliyor).

Yasaklar korundu: yeni saat alani yok, DDR/ODDR/OSER yok, RX/ornekleme yolu
el degmemis.

### 5.1 IKI GERCEK HATA: her iki CRC de naif kenar degisikliginde BOZULUYOR

Gorev tanimi CRC7'yi "dikkat edilmesi gereken hiza" olarak isaretliyordu; bit
bit izlendiginde ikisi de somut birer off-by-one veriyor. Ikisinin de kok
sebebi ayni: **her iki CRC de REGISTERLI ped cikisini katliyor**, yani "bir
onceki kenarda surulen bit"i. Dusen-kenar surusunde araya bir posedge girdigi
icin bu calisiyor; her ikisi posedge'e alinirsa o ara kenar kaybolur.

**(1) CRC7 devir teslimi -- `ultra_sd_cmd.sv`**

`tx_cnt_q == 8` kolunda `cmd_out_q <= crc_q[CRC7_W-1]` var. Bugun son veri biti
(D39) `tx_cnt_q == 9` negedge'inde surulur, ARADAKI posedge'de `crc_q`'ya
katlanir, sonra `tx_cnt_q == 8` negedge'i nihai `crc_q`'yu okur. Her ikisi
posedge'e alininca D39'un katlanmasi ile `crc_q`'nun okunmasi AYNI kenara
duser ve okuma NBA geregi D39'u ICERMEYEN bayat degeri alir. Sonuc: CRC7'nin
son biti yanlis, kart her komutu CRC hatasi olarak reddeder.

Duzeltme tek satir -- o kolda `crc_q` yerine kombinasyonel `crc_nxt`:

    cmd_out_q           <= crc_nxt[CRC7_W-1];
    tx_sh_q[CRC7_W-2:0] <= crc_nxt[CRC7_W-2:0];

`crc_nxt`, o kenarda `crc_q`'ya yazilmakta olan degerin aynisidir, yani tam
olarak nihai CRC. Zamanlama bedeli yok: eklenen `crc_q -> crc7 -> cmd_out_q`
yolu ICERIDE ve tam periyot (20.202 ns) butcesinde; ped yolunu
(`cmd_out_q -> pad`) uzatmiyor.

**(2) CRC16 beslemesi -- `ultra_sd_line.sv`**

`crc_bit = dir_q ? dat_out_q : dat_in_i`. TX'te registerli `dat_out_q`
katlaniyor. Her ikisi posedge'e alininca ayni kenarda `crc_fold_en` bir onceki
cevrimin `in_data`'sini, `crc_bit` ise IKI cevrim oncesinin bitini gosterir --
16 bitlik CRC bastan sona bir bit kaymis olur.

Duzeltme: TX kolunda registerli cikis yerine o kenarda SURULECEK kombinasyonel
degeri katla:

    assign crc_bit = dir_q ? tx_grp : dat_in_i;

(RX kolu `dat_in_i` olarak kalir, dokunulmaz.)

### 5.2 line.sv'de bir cevrimlik kayma ve neden FSM refaktoru gerekiyor

Yukaridaki iki duzeltmeden sonra bile naif kenar degisikligi `ultra_sd_line`'da
NET BIR CEVRIM kayma birakiyor: `cell_q`, `seg_q`, `tx_drive`, `tx_grp`,
`tx_take_o` hepsi posedge alaninda ve cikis blogu posedge'e alininca bunlarin
kenar-oncesi (bir cevrim eski) degerini okur. Cerceve DOGRU cikar ama bir SD
cevrimi GEC cikar; FSM ise `tx_done_q`'yu bir cevrim ERKEN kurar, yani kartin
CRC status token'ini bir cevrim erken dinlemeye baslar ve host hala surerken
dinler.

Bunu kapatmak icin cikis blogunun bir SONRAKI durumun degerlerini gormesi
lazim. `ultra_sd_line`'in FSM'i tek buyuk posedge blogu ve `cell_q`/`seg_q`
yerinde ataniyor -- ayri bir `cell_nxt`/`seg_nxt` YOK. Yani dogru duzeltme ya
bu next-state'i disa cikarmak ya da `dat_out_q`/`dat_oe_q`/`tx_sh_q`
atamalarini FSM'in kendi case kollarinin ICINE tasimak. Ikisi de ~500 satirlik
modulde mekanik ama genis bir refaktor.

`ultra_sd_cmd` tarafinda ayni sorun YOK: orada yuk tetigini `tx_go_q` yerine
`state_q == C_LOAD` yapmak yetiyor, cunku C_LOAD tek cevrimlik ve kosulsuz
C_TX'e geciyor (C_IDLE ve C_GAP, yani ilk gonderim / retry / CMD55 sonrasi
gercek komut, hepsi C_LOAD'dan gecer).

## 6. Uc secenegin karsilastirmasi

Taban: SD saati 49.5 MHz, T = 20.202 ns, okuma 183 Mbit/s, yazma 155 Mbit/s.

| | setup slack | hold | throughput | RTL | yeni saat | risk |
|---|---|---|---|---|---|---|
| **(a)** div 2 -> 4 | +9.879 | serbest (+18.8) | **91 / 78 Mbit/s** (yarisi) | yok | yok | ~sifir |
| **(b)** ped saatini faz kaydir | ~+2.8 .. +9.9 | +1.4 .. +12.2 | **183 / 155** (tam) | yok | PLL faz cikisi | orta/yuksek |
| **(c)** cikis flop'u IOB'ye | ~+0.84 | serbest (+8.7) | **183 / 155** (tam) | yok | yok | dusuk |
| R->R launch (asil onerilen) | +9.879 | **-0.1 .. +0.8** | 183 / 155 | iki blok + uc hiza | yok | yuksek |

### (a) Dusen kenarda kal, SD saatini yavaslat
Pencere 20.202 ns'e cikar, `-0.222` rahatca kapanir, hold zaten serbest.
`sd_clk_core:[F] -> [R]` sinifi KAYBOLMAZ ama ~+9.9 ns payla gecer.
Bedeli throughput'un yarisi. Tasarimin baslik rakami 183 Mbit/s oldugu icin
bu pahali bir takas.

### (b) Ped saatini faz kaydirmak
Gercek cozum ve asil SD HS hostlarinin yaptigi sey. Kosul
`1.4 <= D - phi <= 13.602`, yani ~12 ns genisliginde cok saglam bir pencere.

**Onemli tuzak: duz TERS CEVIRME ise yaramaz.** phi = +/-T/2 = +/-10.101 ns, bugunku
devrenin cebirsel olarak AYNISIDIR (her ikisi de fiziksel modelde setup pay
2.81 ns / hold pay 9.39 ns verir) -- tersleme yalnizca hangi yarim cevrimi
kullandigini degistirir, butceyi buyutmez. Gereken, periyodun TAM KESRI
olmayan gercek bir faz kaymasi: GW2A-18C'de rPLL/PLLVR faz cikisi ya da IO
gecikme elemani. `core_pnr` build'inda `clk` onunde PLL yok (yalnizca bench'te
var), dolayisiyla bu secenek yeni bir saat NESNESI getirir
(`create_generated_clock -phase`) -- CDC anlaminda yeni bir ALAN degil (ayni
kok, tam sayi iliski, senkronizator gerekmez) ama yasagin sinirinda.

### (c) Cikis flop'larini IOB'ye almak
1.06 ns fabric route'u yoldan cikarir. Gorev tanimi bunu hold'u sikan bir
secenek olarak listeliyor -- **bu yalnizca YUKSELEN kenar semasinda dogrudur.**
Bugunku DUSEN kenar semasinda hold'un yarim periyotluk (10.101 ns) yastigi var
ve IOB'nin hold bedeli o yastigin icinde tamamen erir (en kotu D_min ~0.1 ns
ile bile pay ~+8.8 ns).

## 7. ONERI -> bkz. sec. 0

Bu bolumun ilk hali "once (c), dusen kenari koru" diyordu. O oneri yalnizca
"-0.222 ns ihlali kapat" hedefi icin dogruydu; **%20-25 marj hedefi icin
yanlis** -- (c) 54.0 MHz'de (+%9) tavan yapiyor. Gecerli oneri sec. 0'da.

## 8. Bu revizyonda yapilan tek degisiklik: SDC `-min` isareti

`constr/ultra_sd.sdc` ve `bench/constr/bench.sdc`:

    set_output_delay -min  -2.6  ->  -1.4

Gerekce iki satirda: iz gecikmesi veriyi kartta daha GEC vardirir; gec varmak
setup'i zorlastirir ama hold'u KOLAYLASTIRIR, yani 0.6 ns her iki sinira da
ARTI isaretle girer (`-max = iz + tISU = 6.6`, `-min = iz - tIH = -1.4`).
Eski `-2.6 = -(0.6 + 2.0)` izi min tarafinda eksi isaretle sayiyordu, yani ayni
sabit gecikmenin hem setup'i hem hold'u ayni anda sikistirdigini varsayiyordu;
bu fiziksel olarak imkansiz. `-max` satiri zaten dogru konvansiyondaydi,
dosya kendi icinde tutarsizdi. Tam turetme SDC icinde.

Bu hata BUGUN gorunmez (dusen kenar launch'inda hicbir hold yolu bu kisitla
baglanmiyor) ama yukselen kenar degerlendirmesinin on kosuludur: `-2.6` ile
hold `D_min >= 2.6` ister ve her makul kosede duser, yani degisiklik ISARET
HATASI yuzunden reddedilirdi. Duzeltilmis `-1.4` ile soru gercekten acik hale
geliyor.

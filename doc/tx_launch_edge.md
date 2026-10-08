# TX launch kenari: dusen -> yukselen gecisi neden BEKLETILDI

Durum: **uygulanmadi.** Karar, asagidaki hold analizinin mevcut veriyle
kapatilamamasina dayaniyor. RTL'de launch kenari DEGISMEDI; bu revizyonda
yalnizca `set_output_delay -min` isaret hatasi duzeltildi (bkz. en alt).

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

## 7. ONERI

**(c)'yi, bugunku dusen kenar launch'i ile birlikte uygula.**

Raporlanan gercek sorun `-0.222 ns`'lik tek bir setup ihlali. (c) veri
yolundan 1.06 ns alir, yani `-0.222` -> `~+0.84` olur: ihlal kapanir.
Bedeli yok -- throughput tam, yeni saat yok, RTL mantigi degismiyor, DDR
primitifi yok, hold yastigi bozulmuyor. Launch kenarini hic degistirmeye
gerek kalmaz; yukselen kenar yalnizca 49.5 MHz hedefinin ihtiyac duydugundan
cok daha fazla pay istiyorsan gerekir.

Bu yetmezse sira: (b) tam hizi korur ama PLL faz cikisi ister; (a) garanti
calisir ama bandwidth'in yarisini oder; R->R launch ise ancak "Hold Paths
Table" `D_min >= 1.4 ns` gosterirse gundeme gelir.

### Uyari: core_pnr ped sayilari ped ATAMASIZ olculuyor
`syn/core_pnr/build.tcl` bilincli olarak pin atamasi yapmiyor ("ped atamasi
yok", yerlestirici serbest dagitiyor). Dolayisiyla bu sinifin 1.06 ns route ve
3.68 ns ped dokumu gercek pinout'u temsil etmiyor. (c) secenegi ve `D_min`
olcumu, GERCEK `.cst` ile kosan **bench** build'indan da dogrulanmali.

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

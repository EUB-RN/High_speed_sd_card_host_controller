# line ve block mimari analizi — 8 Ekim 2026

Mevcut RTL incelendi; kaynaklara dokunmadan geçici kopyalarda dört sadeleştirme denendi. Öncelikli mimari sorun `block` ile `line` arasındaki başlangıç ve iptal sözleşmesi. Bunun yanında ölçülebilir register tasarrufu sağlayan, arayüz değişikliği gerektirmeyen adaylar da var.

Bu çalışma bir analiz ve deneydir. `experimental.patch` üretim RTL'sine uygulanmadı. Aşağıdaki iki kontrol sorunu deneysel optimizasyonlarla da düzeltilmiş değildir.

## 1. Doğrulanan kontrol sorunları

### FIFO hazır olmadan yazma başlayabiliyor

`rtl/ultra_sd_block.sv:224` içindeki `dat_start_o` yazma kolu yalnızca `S_WR_ARM` ve sekiz çevrimlik boşta bekleme koşuluna bakıyor. Ancak aynı modülün `S_WR_DATA` durumuna geçişi `wr_block_ready_i` koşuluna da bağlı (`:438`). Böylece veri motorunun başlaması ile L3'ün başlaması farklı koşullara bağlı.

Küçük bir L3+L1 entegrasyon testinde, komut cevabı başarılı ve `wr_block_ready_i=0` iken:

```text
EMPTY_WRITE_RESULT early_drive=1 ready=0 wr_en=0 dat_oe=1111 block_state=5 line_state=2
```

L3 hâlâ `S_WR_ARM` durumunda, FIFO tüketim izni kapalı; L1 ise `CELL_XFER` durumunda DAT hatlarını sürüyor. Geciken yazma verisi bu durumda hat üzerindeki çerçeveyle hizalanamaz.

İlk düzeltme adayı, yazma başlangıcını tam blok hazır olmasına da bağlamak. Daha kalıcı çözüm, veri motorunun kabul ettiği başlangıcı açık bir olay olarak L3'e bildirmek. Testte kartın CMD cevabı modelleniyor; gerçek `block` ve `line` RTL'si kullanılıyor, fiziksel kart kullanılmıyor.

### Okuma zaman aşımı line'ı iptal etmiyor

`line` içindeki `CELL_ARM` (`rtl/ultra_sd_line.sv:331`) okuma yönünde DAT0 başlangıç bitini bekliyor. Bu modülde L3'ten gelen bir iptal girişi yok. L3'ün Nac zaman aşımıyla hata/toparlanma yoluna geçmesi, L1'in beklemesini sonlandırmıyor.

Kart DAT başlangıç bitini hiç göndermediğinde test sonucu:

```text
READ_TIMEOUT_RESULT fin=1 block_busy=0 line_rx_busy=1 line_state=1
NEXT_WRITE_RESULT block_state=6 line_state=1 rx_busy=1 dat_oe=0000
```

L3 ilk isteği bitiriyor, fakat L1 `CELL_ARM` durumunda kalıyor. Ardından verilen yazmada L3 `S_WR_DATA` durumuna geçse de L1 hâlâ önceki okumanın başlangıcını bekliyor. DAT0 yüksek kaldığı sürece buradan çıkamıyor.

Çözüm adayı: `line` için açık bir çerçeve iptal/temizleme yolu. İptal, aktif çerçeveyi ve bekleyen başlangıcı temizlemeli; TX çıkış izinleri güvenli saat kenarında bırakılmalı. L3, FIFO rewind ve kart tarafındaki CMD12/CMD13 toparlanmasını ayrıca yürütmeli. L1'in iptali, kart protokolünü toparlama işleminin yerine geçmez.

Kanıtlar: `tb_block_line_contract.sv`, `empty_write.log`, `read_timeout.log`. Bu testbench mevcut sorunun oluştuğunu doğrulayan bir teşhis testidir; normal bir başarı regresyonu değildir.

## 2. Ölçülen sadeleştirmeler

Gowin `syn/build.tcl` ayarlarıyla, tam `ultra_sd_top` hiyerarşisi beş ayrı geçici dizinde sentezlendi. Aşağıdaki değerler hiyerarşik kaynak raporundandır. LUT ve ALU ayrı araç kategorileridir; bunları fiziksel alan olarak doğrudan toplamak doğru değildir. Bunlar P&R sonrası sonuçlar değildir.

| Modül / kaynak | Güncel kaynak kopyası | Birleşik prototip | Azalma |
|---|---:|---:|---:|
| line register | 259 | 223 | 36 |
| line LUT | 409 | 371 | 38 |
| block register | 201 | 177 | 24 |
| block LUT | 402 | 402 | 0 |
| block ALU | 24 | 0 | 24 |
| İki modül toplam register | 460 | 400 | 60 |
| İki modül toplam LUT | 811 | 773 | 38 |

Tüm çekirdek düzeyinde register 1289 → 1229, hiyerarşik LUT 2122 → 2102, ALU 124 → 100; BSRAM 2 ve SSRAM 3 olarak kaldı. Hiyerarşiler arası sentez optimizasyonları nedeniyle modül içi LUT azalmasıyla tüm çekirdeğin LUT azalması aynı değil.

### A. line: ikinci RX kelime register'ını kaldırmak

Mevcut kaynakta 31 bitlik `rx_sh_q` ve 32 bitlik `rx_data_q` var (`rtl/ultra_sd_line.sv:143`). Kelime tamamlandığında veri ikinci register'a kopyalanıyor.

Deneyde kaydırıcı 32 bite çıkarıldı; `rx_data_o` doğrudan bu register'ın sabit endian dönüşümünden üretildi. `rx_valid_o` darbesinin zamanı değişmedi. Aynı saat alanındaki tüketici, geçerli kelimeyi sonraki pozitif kenarda alırken kaydırıcı da yeni kelimenin bitlerini işlemeye devam edebiliyor.

Tek başına bu değişiklikte line: **259 → 228 register, 409 → 380 LUT**. Net 31 register kazancı var.

Sözleşme koşulu: RX verisi yalnızca `rx_valid_o` yüksekken kullanılmalı. `rx_valid_o=0` iken çıkışın son kelimeyi koruması artık garanti edilmiyor. Mevcut FIFO ve başlatma yolu veriyi valid ile tüketiyor. İleride başka saat alanından örnekleme veya backpressure eklenecekse bu karar yeniden değerlendirilmelidir.

### B. line: uzunluk ve ilerlemeyi tek geri sayımda tutmak

Mevcut `word_q`, `xfer_words_q` ve `word_q == xfer_words_q - 1` karşılaştırması (`:188`) yerine tek bir kalan-kelime sayacı kullanılabilir. Başlangıçta `kelime_sayısı - 1` yüklenip sıfır son kelime olarak yorumlanır.

Grup/CRC/token sayacında da `N ... 1` yerine `N-1 ... 0` gösterimi denendi. Varsayılan 32 grupluk üst sınır için sayaç bir bit daralıyor; tüm yükleme ve bitiş koşulları birlikte değiştirildi.

Bu iki sayaç değişikliği tek başına line içinde **5 register ve 7 LUT** azalttı. Kaynak kodundaki bit sayısı farkının tamamı netliste yansımıyor; sentez zaten bazı bitleri azaltıyor. Ayrıca bu tekil varyantta tüm çekirdeğin LUT sayısı arttı. Bu yüzden yalnızca daha kısa RTL'ye bakarak kazanç ilan edilmemeli.

### C. block: toplam blok kaydını bir olay bitine indirmek

`blocks_tot_q` iki amaçla kullanılıyor: ACMD23 ön silme argümanı ve ilk blok tamamlandıktan sonra istatistik sayımını açmak. ACMD23 sırasında `blocks_left_q` henüz azalmamış olduğundan aynı argümanı sağlar. İkinci kullanım için `first_block_done_q` yeterli.

24 bitlik toplam kayıt ve kalan/toplam karşılaştırması kaldırıldı; ilk başarılı blok olayında bir bit set ediliyor. Retry bu biti temizlemiyor, yeni istek temizliyor. Başlangıç ön silmesi yalnızca ilk aktarım başında kaldığı sürece geçerli bir sadeleştirme.

### D. block: komut bekleme durumlarını birleştirmek

`P_ISSUE` ve `P_ACC` aynı çıkışı üretiyor; ikisi de ilk `ready` görüldüğünde `P_WAIT` durumuna geçiyor (`rtl/ultra_sd_block.sv:540`). Deneyde bu üç durum tek `cmd_pending_q` bitine indirildi. Kabul, `req_valid_o && req_ready_i`; bitin temizlenme koşulları mevcut cevap/iptal/durumdan çıkma koşullarıyla aynı.

C ve D birlikte block içinde **24 register ve 24 ALU** azalttı. Tekil block denemesinde LUT 402 → 405 oldu; birleşik prototipte 402 kaldı. Ana kazanç register ve aritmetik/kıyaslama mantığında.

## 3. Daha kapsamlı mimari aday: açık çerçeve kabulü

L3 ve L1 aynı `sd_clk_core` saatinde çalışıyor. Buna rağmen başlangıç iki kademeden geçiriliyor; L3 kabulü `rx_busy` yükselen kenarından çıkarıyor; `arm_left_q` ayrıca başlatılabilecek blokları sayıyor. Bu dolaylı sözleşme hem son blok hesabını hem iptali zorlaştırıyor.

Önerilen arayüz:

```text
block/init → line: frame_valid, direction, length
line → block/init: frame_ready, frame_done, frame_result
block/init → line: frame_cancel

Kabul olayı = frame_valid && frame_ready
```

Yazma isteği ancak tam blok hazırken sunulmalı. Okuma motoru komut gönderilmeden önce hazırlanabilmeli; veri, komut cevabının hemen ardından gelebilir. Kart busy ve gerekli boşluk süreleri hazır olma tanımında korunmalı. `frame_ready` yalnızca FIFO boş/dolu sinyali değildir.

Bu arayüzle 24 bitlik `arm_left_q` yerine kalan blok sayısı ve tek bir aktif çerçeve bilgisinin yeterli olup olmadığı araştırılabilir. **Bu değişiklik henüz denenmedi; kazancı ölçülmedi.** Kesintisiz çoklu okuma, son blok, CRC retry, FIFO doluluğu ve iptal sınırları birlikte doğrulanmadan sayaç kaldırılamaz.

`start_sync_q` aynı saat alanında bir boru hattı; yeni sözleşmeyle kaldırılabilir. `wide_sync_q` ise gerçek saat alanı geçişini koruyor; onun kaldırılması önerilmiyor. `arm_idle_q` içindeki bekleme de salt gereksiz gecikme sayılmamalı: DAT0 busy gözlemi ve token sonrası geçişlerle birlikte yeniden tasarlanmalı.

## 4. Korunması gereken paylaşım ve maliyetler

- line'da TX ve RX zaten ortak durum/segment kontrolünü ve CRC bankasını kullanıyor.
- 4-bit veri akışında dört CRC16 hattı aynı anda ilerliyor. Mevcut saat ve throughput korunurken bu bankayı tek seri CRC'ye indirmek uygun değil.
- TX kaydırıcı düşen, RX kaydırıcı yükselen kenarda çalışıyor. Yalnızca yarı çift yönlü oldukları gerekçesiyle bunları tek register'a birleştirmek basit bir alan optimizasyonu değil.
- `word_swizzle` parametreyle seçilen sabit kablolama; çalışma anında genel bir byte sıralama motoru değil.
- line'ın iki istatistik sayacı 56 bit; block'un istatistik sayaçları 40 bit tutuyor. Bunları opsiyonel yapmak ayrı bir alan seçeneği olabilir, fakat gözlemlenebilir istatistik davranışını değiştirir. Ölçülen prototip bu sayaçları koruyor.

## 5. Doğrulama ve sınırlar

Başlangıç kopyası ve birleşik prototipte aşağıdaki mevcut testler geçti:

- `ultra_sd_line`: 1-bit/4-bit TX/RX, bağımsız CRC referansı, bozuk veri, yazma durum token'ları ve token zaman aşımı.
- `block_requests`: 59 kontrol.
- `block_flow`: 91 kontrol.
- `block_axis_read`: 133 kontrol.
- `block_axis_write`: 262 kontrol.
- `block_stat`: 10 kontrol.
- `top_integration`: 29 kontrol.
- `sd_card_model`: 35 kontrol.

Ek olarak line testi 4, 64 ve 512 bayt çerçeve uzunluklarına uyarlanıp iki sürümde de çalıştırıldı; mevcut testin 8 bayt koşumuyla birlikte dört uzunluk denendi. İki sürümde `make lint` başarılı.

Bu testler, teşhis testinin ortaya çıkardığı iki mevcut kontrol sorununu kapsamıyor. Regresyonun geçmesi bu sorunların bulunmadığı anlamına gelmiyor. Prototip için tüm parametre kombinasyonları, formal eşdeğerlik, P&R ve fiziksel kart testi yapılmadı. `bench_flow` bu analizde çalıştırılmadı.

Sentez zamanlama özetinde SD saati için tahmin 74.349 → 78.113 MHz. Bu bir P&R sonucu veya ölçülmüş kart hızı değil. Başlangıç sentezindeki ilk kritik yol `u_block/step_q` → `u_cmd/tx_sh_q`; dolayısıyla line alanını küçültmek en kötü zamanlama yolunu doğrudan çözmüyor.

## 6. Uygulama sırası

1. FIFO hazır olmadan line'ın yazmayı başlatmasını engelle; ilgili entegrasyon testini normal regresyona dönüştür.
2. Okuma zaman aşımı/iptal sonrası line'ı yeniden kullanılabilir hale getiren çerçeve iptal sözleşmesini ekle.
3. Ölçülen RX register, sayaç ve block durum sadeleştirmelerini küçük değişiklikler halinde uygula.
4. Açık çerçeve kabulüyle `arm_left_q` ve başlangıç boru hattını birlikte yeniden değerlendir.
5. Son aday için tam entegrasyon regresyonu, P&R ve kart üzerinde ardışık okuma/yazma ile hata sonrası toparlanmayı doğrula.

## Yeniden üretim

Deney klasörü: `/tmp/sd-line-block-analysis-ajtbl5il`. Kalıcı dosyalar bu raporun yanında; `source_hashes.json` analiz edilen RTL ve kısıtların SHA-256 özetlerini içeriyor. `experimental.patch` yalnızca alan deneyindeki değişiklikleri içerir, kontrol sorunlarının düzeltmelerini içermez.

Teşhis testi proje kökünden şöyle çalıştırılabilir:

```bash
iverilog -g2012 -s tb_block_line_contract -o /tmp/line_block_contract.vvp \
  rtl/ultra_sd_pkg.sv rtl/crc/ultra_sd_crc16.sv \
  rtl/ultra_sd_block.sv rtl/ultra_sd_line.sv \
  reports/line_block_analysis_20261008/tb_block_line_contract.sv
vvp /tmp/line_block_contract.vvp
vvp /tmp/line_block_contract.vvp +read_timeout
```

Kaynak sayaçları: `measurements.json`, `baseline_resources.html`, `combined_resources.html`. Test özetleri: `baseline_test_summary.txt`, `combined_test_summary.txt`.

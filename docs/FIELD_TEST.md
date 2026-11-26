# Saha testi rehberi

Amaç: iOS'un uygulamayı arka planda gerçekten uyandırıp uyandırmadığını ve algılamanın gerçek sürüşte doğru çalışıp çalışmadığını ölçmek (DECISIONS: "Riskler ve açık konular").

## 1. Bir kerelik kurulum (Apple Developer onayından sonra)
```powershell
npx eas-cli@latest login
```
```powershell
npx eas-cli@latest init
```
```powershell
npx eas-cli@latest device:create
```
`device:create` bir bağlantı verir; iPhone'da açınca telefon derleme listesine eklenir.

## 2. Development build
```powershell
npx eas-cli@latest build -p ios --profile development
```
Bitince gelen QR kodu iPhone kamerasıyla okut ve yükle. İlk açılışta Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu'nu aç. Arayüz değişikliklerini canlı görmek için bilgisayarda `npx expo start --dev-client`.

Development build Debug derlemedir: **sensör kaydı açıktır** (ham konum içerir). Yalnızca kendi telefonunda kullan; başka birine dağıtma.

## 3. İzinler
Uygulama sırayla konum, hareket ve "Her Zaman" ister. Saha testi için üçünü de ver; "Her Zaman" olmadan arka planda algılama çalışmaz. Ana ekran → Teşhis'te "Konum → Yetki: Her Zaman" görünmeli.

## 4. Senaryolar (her biri en az bir kez)
| Senaryo | Beklenen |
|---|---|
| Normal sürüş, uygulama kapalı, telefon cepte | Yolculuk kendiliğinden başlar ve biter, park yazılır |
| Trafik ışığı, 2 dk sıkışık trafik | Yolculuk bölünmez, yolda park yok |
| Park edip yürüme | Park noktası aracın yanında, yürüdüğün yerde değil |
| Kapalı otopark | Düşük güvenli park, giriş civarında |
| Otobüs / taksi | "Belirsiz" yolculuk, park yazılmaz |
| Benzin istasyonu, inip binme | Tek yolculuk |
| Telefonu araçta unutma | 15 dk sonra düşük güvenli park, GPS (mavi gösterge) söner |
| Uygulamayı zorla kapatıp sürme | Geofence'ten çıkınca uyanma — **en önemli test** |
| Telefonu yeniden başlatıp kilidi açmadan sürme | Yolculuk rotasız kaydedilir, çökme yok |

Her testten sonra Teşhis ekranında uyarı (turuncu ikon) var mı bak; varsa ekran görüntüsü al.

## 5. Sensör kayıtlarını aktarma
Kayıtlar **gerçek konum ve rota** içerir (ev, iş, park yerlerin). Repoya ekleme, kimseyle paylaşma.

**Telefondan Windows bilgisayara (bilinçli tek istisna: iCloud, hemen silinerek):**
1. Ana ekran → Teşhis → "Sensör kayıtları (debug)" → ilgili günün dosyası → paylaş → **Dosyalar'a Kaydet → iCloud Drive** içinde `carcrumb-trace` adlı bir klasör.
2. Bilgisayarda iCloud for Windows ya da icloud.com üzerinden dosyayı indir; proje klasörünün **dışına** koy (örn. `Belgeler\carcrumb-ham`).
3. Hemen iCloud'dan sil, ardından **Son Silinenler**'den de sil (iPhone: Dosyalar → Göz At → Son Silinenler).

**Analiz için bana (yapay zekâ asistanına) vermeden önce mutlaka anonimleştir.** Ham dosyayı sohbete vermek, gerçek konumları harici bir servise göndermek demektir. Betik yerelde çalışır, internete çıkmaz:
```powershell
node scripts/anonymize-trace.js "$HOME\Documents\carcrumb-ham\trace-2026-12-01.jsonl" "$HOME\Documents\carcrumb-ham\anon-2026-12-01.jsonl"
```
Betik koordinatları rastgele bir açıyla döndürüp sentetik noktaya (41.0 / −40.0, Atlantik ortası) taşır, tarihleri rastgele gün sayısı kadar kaydırır; mesafeler ve hızlar korunduğu için algılama aynı şekilde yeniden oynatılır. Bana yalnızca `anon-…` dosyasını ver. Mümkünse yalnızca sorunun yaşandığı kısa bölümü ver: rotanın şekli dönse de korunur.

- Ham dosyayla işin bitince bilgisayarından da sil.
- `fixtures/traces/` altına yalnızca `synthetic_*` dosyaları girebilir; CI hem adı hem koordinat kutusunu kontrol eder. Anonim kaydı fixture'a ben çevirip ekleyeceğim.
- Test bitince uygulamada "Geçmişi sil" telefonun içindeki kayıtları da siler; debug kayıtları ayrıca 14 gün sonra kendiliğinden silinir.

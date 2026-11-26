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
Ana ekran → Teşhis → "Sensör kayıtları (debug)" → ilgili günün dosyası → paylaş → AirDrop/Dosyalar ile **kendi bilgisayarına** al.

- Kayıtlar **gerçek konum ve rota** içerir: repoya ekleme, kimseyle paylaşma, bulut klasörüne koyma.
- `fixtures/traces/` altına yalnızca `synthetic_*` dosyaları girebilir; CI gerçek kayıtları (ad ve koordinat kutusu kontrolü) reddeder.
- Analiz için kaydı bana ver; ilgili bölümü sentetik kutuya (41.0 / −40.0) taşınmış bir fixture'a çevirip kalıcı regresyon testi yaparım.

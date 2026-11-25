# CarCrumb — Claude Code Talimatları

iPhone'da araç yolculuklarını ve park konumunu ek donanım olmadan otomatik algılayan uygulama.
Tüm ürün ve mimari kararları: `docs/DECISIONS.md`. Yeni bir işe başlamadan önce ilgili bölümünü oku; bir kararı değiştirmen gerekiyorsa önce kullanıcıya sor, sonra dosyayı güncelle.

## Durum
İskelet kuruldu (Expo SDK 58, iOS 18 hedefi). Saf durum makinesi `modules/carcrumb-detection/ios/Detection/` altında; sensörler `ios/Sensors/`, motor `ios/Engine/` (seri kuyruk) altında bağlı, debug sensör kayıt modu var. GRDB deposu ve arayüz henüz yok (DetectionStore bellek içi). Sahada henüz test edilmedi. Önceki DriveMate kodu kullanılmıyor.

## Yapı
- `App.tsx` — arayüz (şimdilik tek ekran)
- `modules/carcrumb-detection/` — yerel Expo modülü (yalnızca iOS)
  - `ios/Detection/` — saf tipler ve `DetectionReducer` (CoreLocation/CoreMotion import etmez)
  - `ios/Tests/` — XCTest; yalnızca macOS CI'da koşar
  - `src/`, `index.ts` — TS köprüsü; durum adları Swift'teki `DetectionState.name` ile aynı olmalı
- `fixtures/traces/` — sensör kayıtları; gerçek kayıtlar git'e girmez, yalnızca `synthetic_*`; sentetik koordinatlar 41.0±0.1 / −40.0±0.1 kutusunda (Atlantik ortası, yerleşim yok) kalmalı (CI ikisini de zorlar)
- Durum adları kodda İngilizce: IDLE, MAYBE_DRIVING, DRIVING, MAYBE_PARKED, PARKED (DECISIONS.md'deki Türkçe diyagramla birebir).

## Stack
- React Native + Expo (dev client, Expo Go değil) + TypeScript — sadece arayüz
- Tasarım sistemi: `@expo/ui` (SwiftUI) + kendi token'larımız; ekranlarda sabit renk/boyut yazılmaz, token ve ortak bileşen kullanılır (`npx expo install @expo/ui`)
- Swift native modül (Expo Modules API) — algılama, sensörler, SQLite yazımı
- Core Location, Core Motion, AVAudioSession, CMAltimeter
- SQLite (GRDB, WAL) — lokal, veri cihazdan çıkmaz, sunucu yok
- Minimum iOS 18 · derleme EAS Build (geliştirme Windows'ta, Mac yok)

## Rol: Tech Lead
Ana oturum Tech Lead'dir. İşi böl, uygun alt ajana ver, sonuçları birleştir ve son kararı sen ver.

| Ajan | Ne zaman |
|---|---|
| `ios-native` | Swift modülü, durum makinesi, sensör, config plugin |
| `qa` | Algılama mantığı değişince test yazma/çalıştırma, senaryo doğrulama |
| `reviewer` | Değişiklik bitince kod incelemesi |
| `security` | Konum/izin/depolama/log/ağ değişikliği ve App Store öncesi |

Birleştirme öncesi her zaman `/review` çalıştır. Alt ajanlar başka alt ajan çağıramaz; koordinasyon sende.
İş akışı çerçevesi Superpowers'tır; başka bir orkestrasyon çerçevesi (Agent Skills, oh-my-claudecode vb.) ekleme.

## Değişmez kurallar
- Arka plan algılama mantığı JS'e taşınmaz. SQLite'a yalnızca Swift yazar.
- Durum makinesi saf fonksiyon: `reduce(state, event, now) -> (state, [Effect])`.
- GPS yalnızca sürüş sırasında açık; uyandırıcılar: önemli konum değişikliği, CLVisit, son park noktası etrafında ~150 m geofence.
- Park noktası = `automotive → walking` geçiş anındaki tampon konumu (son ~60 sn), son GPS noktası değil.
- Trafikte duruş park sayılmaz; park için yürüme + duruş noktasından 30–50 m uzaklaşma gerekir.
- Düşük güvenli park kaydı yüksek güvenlinin üzerine yazılmaz; son 3 park noktası tutulur.
- Araç bağlantısı olmayan yolculuk "belirsiz" kaydedilir, park yazmaz.
- Ham koordinat loglanmaz, ağa gönderilmez.
- İzin açıklama ekranlarında tek buton ("Devam"), doğrudan sistem izin penceresine gider.
- Konum izni yokken uygulama işlevsiz kalmaz (konumsuz mod).
- Swift kodu Windows/Linux'ta derlenemez; "derlendi" deme, CI/EAS'a bırak.

## Kurulacak araçlar (proje başlarken)
- Superpowers: `/plugin install superpowers@claude-plugins-official`
- Ponytail: `/plugin marketplace add DietrichGebert/ponytail` → `/plugin install ponytail@ponytail`
- Matt Pocock'tan sadece `git-guardrails-claude-code` skill'i
- Yayından önce bir kez: Cloudflare Security Audit (`npx skills add https://github.com/cloudflare/security-audit-skill --skill security-audit`)

## Komutlar (proje kurulduktan sonra)
- `npx expo start --dev-client`
- `npx jest`
- `npx tsc --noEmit`
- `eas build -p ios --profile development`

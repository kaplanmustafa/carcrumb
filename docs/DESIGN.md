# CarCrumb Tasarım Sistemi

Karar: `@expo/ui` (gerçek SwiftUI bileşenleri) + kendi token'larımız (DECISIONS.md, "Teknik kararlar").

## Kurallar
- Ekranlar ham stil değeri yazmaz: renk kodu, `fontSize`/`fontWeight`, `StyleSheet` ve `@expo/ui/swift-ui/modifiers` yalnızca `src/design/` içinde. `src/design/__tests__/no-raw-styles.test.ts` bunu Jest'te zorlar.
- Renkler sistemin anlamsal renkleri; açık/koyu mod, Artırılmış Kontrast ve Dynamic Type sistemden gelir. Tek marka rengi: `color.accent` (indigo).
- Renk tek başına anlam taşımaz: durum her zaman ikon + metinle birlikte gösterilir.
- Tipografi yalnızca SwiftUI metin stilleriyle; sabit punto yok.
- Aynı kavram her yerde aynı SF Symbol'ü kullanır (`icon` token'ı).
- İzin açıklama ekranlarında tek buton ("Devam") — `PrimaryButton`, ikinci buton yok (CLAUDE.md).

## Dosyalar
- `src/design/tokens.ts` — `color`, `space`, `radius`, `type` (rol → metin stili), `icon` (kavram → SF Symbol).
- `src/design/components.tsx`:

| Bileşen | SwiftUI karşılığı | Kullanım |
|---|---|---|
| `Screen` | Host + NavigationStack + Form | Her ekranın kökü, büyük başlık |
| `Group` | Section | Başlıklı satır grubu, isteğe bağlı açıklama |
| `Txt` | Text + font + foregroundStyle | `role`: display, title, heading, body, secondary, caption, metric |
| `StatusLabel` | Label | İkon + metin, durum rengiyle |
| `InfoRow` | LabeledContent | Ayarlar tarzı etiket/değer satırı |
| `PrimaryButton` / `SecondaryButton` | Button (borderedProminent / bordered) | Ekranın ana / ikincil eylemi |
| `EmptyState` | ContentUnavailableView | Boş içerik, konum kapalı vb. |

- `src/features/detection/presentation.ts` — algılama durumlarının başlık, açıklama, ikon ve renk tonu.

## Yeni bileşen eklerken
Önce mevcut bileşenlerle yapılabiliyor mu bak. Gerekirse `components.tsx`'e ekle; modifier'lar ve token erişimi orada kalır, ekran yalnızca bileşeni kullanır.

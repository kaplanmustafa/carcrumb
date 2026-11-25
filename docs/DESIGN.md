# CarCrumb Tasarım Sistemi

Karar: `@expo/ui` (gerçek SwiftUI bileşenleri) + kendi token'larımız (DECISIONS.md, "Teknik kararlar").

## Kurallar
- Ekranlar ham stil değeri yazmaz: renk ve boyut literal'leri, `fontSize`/`fontWeight`, `StyleSheet`, `PlatformColor`, `modifiers` prop'u ve `@expo/ui` importları yalnızca `src/design/` içinde. `src/design/__tests__/no-raw-styles.test.ts` bunu Jest'te zorlar.
- Renkler sistemin anlamsal renkleri; açık/koyu mod, Artırılmış Kontrast ve Dynamic Type sistemden gelir. Tek marka rengi: `color.accent` (indigo).
- Renk tek başına anlam taşımaz: durum her zaman ikon + metinle birlikte gösterilir.
- Tipografi yalnızca SwiftUI metin stilleriyle; sabit punto yok.
- Aynı kavram her yerde aynı SF Symbol'ü kullanır (`icon` token'ı).
- İzin açıklama ekranları yalnızca `PermissionScreen` ile yapılır: tek buton ("Devam"), ikinci buton verilemez (CLAUDE.md).
- Durum rengi yalnızca ikona uygulanır; metin her zaman metin renginde kalır (sistem yeşili/turuncusu beyaz üzerinde 3:1'in altında).

## Dosyalar
- `src/design/tokens.ts` — `color`, `space`, `radius`, `typography` (rol → metin stili), `icon` (kavram → SF Symbol).
- `src/design/components.tsx`:

| Bileşen | SwiftUI karşılığı | Kullanım |
|---|---|---|
| `Screen` | Host + NavigationStack + Form | Her ekranın kökü, büyük başlık |
| `Section` | Section | Başlıklı satır grubu, isteğe bağlı açıklama |
| `PermissionScreen` | Host + ContentUnavailableView | İzin açıklaması; sabit tek "Devam" butonu |
| `Txt` | Text + font + foregroundStyle | `role`: display, title, heading, body, secondary, caption, metric |
| `StatusLabel` | Label + Image | İkon durum renginde, başlık metin renginde |
| `InfoRow` | LabeledContent | Ayarlar tarzı etiket/değer satırı |
| `PrimaryButton` / `SecondaryButton` | Button (borderedProminent / bordered) | Ekranın ana / ikincil eylemi |
| `EmptyState` | ContentUnavailableView | Boş içerik, konum kapalı vb. |

- `src/features/detection/presentation.ts` — algılama durumlarının başlık, açıklama, ikon ve renk tonu.

## Yeni bileşen eklerken
Önce mevcut bileşenlerle yapılabiliyor mu bak. Gerekirse `components.tsx`'e ekle; modifier'lar ve token erişimi orada kalır, ekran yalnızca bileşeni kullanır.

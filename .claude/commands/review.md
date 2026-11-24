---
description: Mevcut değişiklikleri reviewer, qa ve security ajanlarıyla paralel incele ve tek rapor üret
argument-hint: "[git aralığı, varsayılan main...HEAD]"
---

İncelenecek aralık: $ARGUMENTS (boşsa `main...HEAD`).

1. `git diff --stat` ile değişen dosyaları çıkar.
2. **reviewer**, **qa** ve **security** alt ajanlarını aynı anda (paralel) başlat; her birine aralığı ve değişen dosya listesini ver.
3. Raporlar gelince Tech Lead olarak birleştir:
   - Tekrarlanan bulguları tek maddede topla.
   - Seviyeye göre sırala: kritik → önemli → küçük.
   - Ajanlar arasında çelişki varsa kodu kendin okuyup karar ver.
4. Sonuç: **ONAY** / **DÜZELTME GEREKLİ** kararı, gerekçe ve yapılacaklar listesi.
5. Kullanıcı isterse düzeltmeleri **ios-native** ajanına veya kendine ata, sonra `/review` yeniden çalıştır.

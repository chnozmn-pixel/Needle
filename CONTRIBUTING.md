# Contributing to Needle / Needle'a Katkı

**EN** — Thanks for helping improve Needle. This document covers the local setup,
the checks we expect before a pull request, and a few ground rules.

**TR** — Needle'ı geliştirmenize yardım ettiğiniz için teşekkürler. Bu belge yerel
kurulumu, pull request öncesi beklenen kontrolleri ve birkaç temel kuralı
anlatıyor.

## Requirements / Gereksinimler

- macOS 13 or newer / macOS 13 veya üzeri
- Swift 5.9 (ships with Xcode 15+) / Swift 5.9 (Xcode 15+ ile gelir)
- No third-party package dependencies / Üçüncü taraf paket bağımlılığı yok

## Build and test / Derleme ve test

```bash
swift build
swift test
./scripts/build-app.sh      # assembles dist/Needle.app
open dist/Needle.app
```

A release ZIP and a matching Homebrew cask SHA-256 are produced by:

```bash
./scripts/package-release.sh
```

**EN** — `package-release.sh` also bumps nothing automatically: update
`Resources/Info.plist`, the README version references, and `Casks/needle.rb`
together in the same commit.

**TR** — `package-release.sh` sürümü otomatik artırmaz: `Resources/Info.plist`,
README'deki sürüm referansları ve `Casks/needle.rb` aynı commit içinde
güncellenmelidir.

## Pull requests / Pull request'ler

1. Open an issue first for larger changes so the approach can be discussed.
   / Büyük değişiklikler için önce bir issue açın, yaklaşım tartışılsın.
2. Keep one logical change per pull request. / Her PR tek bir mantıksal değişiklik
   içersin.
3. Run `swift test` and `swift build` before submitting. / Göndermeden önce
   `swift test` ve `swift build` çalıştırın.
4. Describe what changed, how you verified it, and any UI strings you added.
   / Neyin değiştiğini, nasıl doğruladığınızı ve eklediğiniz arayüz metinlerini
   yazın.
5. New user-facing strings use `L("...")` with a Turkish source key. Add the
   English translation to `TranslationTables.english` — English must not
   contain Turkish characters. / Yeni arayüz metinleri Türkçe kaynak anahtarla
   `L("...")` kullanır. İngilizce çeviriyi `TranslationTables.english` içine
   ekleyin; İngilizcede Türkçe karakter olmamalı.
6. Update both the English and Turkish README sections when behaviour or syntax
   changes. / Davranış veya sözdizimi değiştiğinde README'nin hem İngilizce hem
   Türkçe bölümünü güncelleyin.

## Reporting problems / Sorun bildirme

Use the issue templates for bugs and feature requests. For security issues,
follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
/ Hatalar ve özellik istekleri için issue şablonlarını kullanın. Güvenlik
sorunlarında herkese açık issue açmak yerine [SECURITY.md](SECURITY.md)
yönergelerini izleyin.

By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
/ Katılımınızla [Davranış Kuralları](CODE_OF_CONDUCT.md) belgesini kabul etmiş
olursunuz.

# Needle

**Language / Dil:** [English](#needle) · [Türkçe](#turkce)

Fast, private, local file search for macOS — inspired by voidtools Everything.

Needle builds **its own index**. It does not require an Everything installation,
a Windows machine, or a cloud service. Search results update while you type.

> Kısa özet: Needle, macOS için Everything benzeri yerel bir dosya arama
> uygulamasıdır. Kendi SQLite indeksini oluşturur, FSEvents ile yerel değişiklikleri
> anında yakalar, ağ birimlerini ayarlanabilir bir zamanlamada tarar ve varsayılan
> olarak İngilizce arayüzle gelir. Aşağıda [tam Türkçe anlatım](#turkce) bulunur.

## What it actually does

- **Own persistent index** — file/folder names, full paths, size, creation and
  modification dates are stored in SQLite at
  `~/Library/Application Support/Needle/index.sqlite`.
  A restart does not force a full rescan.
- **Live search** — an in-memory n-gram index over names and paths keeps typing
  responsive, including while the first scan is still running. No Enter key is
  needed; results narrow as you type.
- **Instant local updates** — `FSEvents` watches local volumes and applies
  create/change/delete/rename changes incrementally instead of rescanning the
  whole disk.
- **Network folders** — SMB/AFP mounts can be added as roots. Because FSEvents
  is unreliable on network shares, network roots are reconciled on a schedule:
  **daily at 02:00 by default**, with options for idle time, hourly, or every
  5 minutes. Local disks keep live FSEvents monitoring.
- **Spotlight enrichment (optional)** — `mdfind` can fill gaps for files that
  are not in Needle's own index or that live on network volumes.
- **Everything-style query language** — `|`, `!`, groups, quotes, wildcards,
  `ext:`, `path:`, `parent:`, `root:`, `file`, `folder`, `size:`, date filters,
  `content:`, `child:`, `empty:`, `dupe:`, `distinct:`, `count:`, `sort:`,
  macros (`audio:`, `image:`, `video:`, `zip:`) and character entities.
- **Workflow features** — saved searches, search/run history, advanced search,
  properties, CSV/text export, configurable columns, themes, Quick Look,
  Finder actions, global hotkey and a loopback-only HTTP/JSON search server
  (disabled by default).
- **Privacy** — indexing and search happen locally. The HTTP server binds only
  to `127.0.0.1` and must be enabled explicitly.

Needle is **Everything-inspired, not binary-compatible**. The ETP network
protocol and a few advanced Everything features are not implemented. See the
Scope notes below.

## Requirements

- macOS 13 or newer
- Apple Silicon or Intel
- For source builds: Xcode Command Line Tools (`xcode-select --install`)

## Install from GitHub

The project repository is https://github.com/chnozmn-pixel/Needle .

### 1. Release ZIP — recommended for end users

1. Open the repository's **Releases** page.
2. Download `Needle-0.1.0.zip`.
3. Unzip it and move `Needle.app` to `/Applications`.
4. Launch it. The first run indexes your home folder.

The release app is **ad-hoc signed**. On a Mac that blocks it, right-click the
app and choose **Open**, or approve it under
**System Settings → Privacy & Security** once. There is no installer and no
background daemon.

### 2. Build from source with SwiftPM

This is the simplest auditable route: you compile exactly the code in the repo.

```bash
git clone https://github.com/chnozmn-pixel/Needle.git
cd Needle
chmod +x scripts/*.sh
./scripts/build-app.sh
open dist/Needle.app
```

`scripts/build-app.sh` runs `swift build -c release`, assembles the `.app`
bundle, copies the icon and `Info.plist`, and ad-hoc signs it. The output is
`dist/Needle.app`.

### 3. Homebrew Cask from this repository

A Cask definition is included at `Casks/needle.rb`. The SHA-256 is refreshed
from `scripts/package-release.sh` for every release. After the Cask is
published in a tap:

```bash
brew tap chnozmn-pixel/needle
brew install --cask needle
```

The Cask downloads the release ZIP, verifies its SHA-256, installs
`Needle.app` into `/Applications`, and defines a `zap` block that removes
Needle's support files if you uninstall it.

For a local test before publishing a tap:

```bash
brew install --cask ./Casks/needle.rb
```

### 4. Run directly from a checkout — development

```bash
swift run Needle
```

This builds a debug binary and uses the same index database. It is intended for
development, not as the normal installation path.

### Maintainers: create a release ZIP

```bash
./scripts/package-release.sh
# prints dist/Needle-0.1.0.zip and its SHA-256
```

Upload that ZIP to the GitHub Release and copy the SHA-256 into the Cask.

## First run

- Needle indexes your home folder automatically. You can add/remove roots in
  **Settings → Roots**.
- The bottom bar shows live scan progress and entry counts.
- `⌘⇧Space` brings the window forward. `⏎` opens, `⌘⏎` shows in Finder,
  `Space` opens Quick Look, `⌘⇧C` copies paths.
- The default UI language is **English**. Settings offers system language plus
  Turkish, German, Spanish, French, Italian, Portuguese, Japanese, Simplified
  Chinese, Korean, Russian, Arabic and Hindi. Switching is instant; untranslated
  strings fall back to English.

## Search syntax

| Example | Meaning |
| --- | --- |
| `report` | Names containing "report" |
| `"annual report"` | Exact phrase |
| `apple \| pear` | OR |
| `<apple pear> \| banana` | Group + OR |
| `!tmp` | Exclude "tmp" |
| `ext:pdf;docx` | PDF or DOCX |
| `path:projects` | Match in full path |
| `file  size:>10mb` | Files over 10 MB |
| `dm:today` | Modified today |
| `content:needle` | Search file contents |
| `dupe:size;content` | Duplicate files |
| `distinct:name` | Unique results |

A space means AND, `|` means OR and `!` means NOT. See the in-app
**Settings → Syntax** tab for the full reference.

## Architecture

| Layer | Responsibility |
| --- | --- |
| `FileSystem.scan` | Walks selected roots with POSIX `opendir`/`readdir`/`lstat`, batches metadata and writes to SQLite. |
| `IndexDatabase` | Persistent WAL-mode SQLite database and incremental upserts/deletes. |
| `SearchEngine` | In-memory snapshot with 1/2/3-byte reversed n-gram posting lists; verifies real substrings after candidate intersection. |
| `FSEventsWatcher` | Live local-volume change stream; only affected records are updated. |
| `SpotlightSearch` | Optional `mdfind` enrichment for gaps and network volumes. |
| `IndexStore` / `IndexCoordinator` | Scan lifecycle, network schedule, published status for SwiftUI. |
| `NeedleApp` | SwiftUI interface, hotkeys, Quick Look, export and settings. |
| `LocalizationManager` | Runtime language switching with English fallback. |

IDs are 64-bit FNV-1a hashes of normalized full paths, not inodes, so they stay
stable across network shares.

## Scope notes

Implemented: persistent index, live search, FSEvents, network roots with
scheduling, Spotlight enrichment, Everything-style query parsing, content and
duplicate search, sorting, export, HTTP/JSON endpoint, localization and the
interface features listed above.

Not implemented yet: the ETP binary protocol, full file-list import/export
parity, index journal/property parity, advanced index-location controls and
the last details of custom sort/configuration. Contributions are welcome.

## Tests

```bash
swift test
```

The suite covers query parsing, n-gram search, incremental index updates,
advanced queries, network scheduling state, HTTP endpoints and localization
fallback/audit checks.

## Project layout

```
Sources/
  NeedleCore/    # index, SQLite, scanner, FSEvents, search engine, parser, localization
  NeedleApp/     # SwiftUI interface
  CSQLite/       # system sqlite3 module map
Tests/NeedleTests/
scripts/
  build-app.sh
  package-release.sh
Casks/needle.rb
Resources/Needle.icns
```

## License and credits

Needle is released under the [MIT License](LICENSE).

References and thanks are listed separately in
[ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md). In short: thanks to voidtools for
documenting the search language that inspired this project, to Apple and the
SQLite project for the platform foundations, and to everyone who tested and
reported issues.

---

<a id="turkce"></a>

# Needle — Türkçe

macOS için voidtools Everything’den esinlenen, **yerel ve hızlı** bir dosya arama
uygulaması. [İngilizce bölüme dön](#needle).

Needle kendi indeksini oluşturur; Everything kurulumuna, Windows makinesine veya
bulut servisine ihtiyacı yoktur. Yazarken sonuçlar anında güncellenir.

## Ne işe yarar?

- **Kendi kalıcı indeksi** — dosya/klasör adları, tam yollar, boyut, oluşturma ve
  değiştirme tarihleri SQLite’a yazılır:
  `~/Library/Application Support/Needle/index.sqlite`.
  Yeniden başlatmak tam taramaya yol açmaz.
- **Canlı arama —** adlar ve yollar üzerinde bellek içi n-gram indeksi sayesinde
  ilk tarama sürerken bile yazmak akıcıdır. Enter’a basman gerekmez; yazdıkça
  sonuçlar daralır.
- **Anlık yerel güncelleme —** `FSEvents` yerel disklerdeki değişiklikleri izler;
  diski baştan taramak yerine sadece ilgili kayıt güncellenir/silinir.
- **Ağ klasörleri —** SMB/AFP paylaşımları kök olarak eklenebilir. FSEvents ağ
  paylaşımlarında güvenilmez olduğu için ağ kökleri zamanlamayla taranır:
  **varsayılan olarak her gün 02:00**; ayrıca boşta iken, saatlik veya 5 dakikada
  bir seçenekleri vardır. Yerel diskler canlı FSEvents izlemeye devam eder.
- **Spotlight ile zenginleştirme (isteğe bağlı)** — kendi indeksinde olmayan veya
  ağ birimindeki dosyalar `mdfind` ile tamamlanabilir.
- **Everything tarzı sorgu dili —** `|`, `!`, gruplar, tırnaklı ifadeler,
  joker karakterler, `ext:`, `path:`, `parent:`, `root:`, `file`, `folder`,
  `size:`, tarih filtreleri, `content:`, `child:`, `empty:`, `dupe:`,
  `distinct:`, `count:`, `sort:`, makrolar (`audio:`, `image:`, `video:`, `zip:`)
  ve karakter varlıkları.
- **İş akışı özellikleri —** kayıtlı aramalar, arama/geçmiş, gelişmiş arama,
  özellikler, CSV/metin dışa aktarma, ayarlanabilir sütunlar, temalar, Quick Look,
  Finder işlemleri, global kısayol ve varsayılan olarak kapalı, yalnızca
  `127.0.0.1`’e bağlanan HTTP/JSON arama sunucusu.
- **Gizlilik —** indeksleme ve arama tamamen yereldir. HTTP sunucusu sadece
  localhost’a bağlanır ve açıkça etkinleştirilmelidir.

Needle **Everything’den esinlenmiştir, ikili uyumlu değildir**. ETP ağ protokolü
ve bazı gelişmiş Everything özellikleri henüz yoktur; aşağıdaki kapsam notlarına
bakın.

## Gereksinimler

- macOS 13 veya üzeri
- Apple Silicon ya da Intel
- Kaynaktan derleme için Xcode Command Line Tools (`xcode-select --install`)

## GitHub’dan kurulum

Proje adresi: https://github.com/chnozmn-pixel/Needle

### 1. Release ZIP — son kullanıcı için önerilen

1. Repo’nun **Releases** sayfasını açın.
2. `Needle-0.1.0.zip` dosyasını indirin.
3. ZIP’i açın ve `Needle.app` uygulamasını `/Applications` içine taşıyın.
4. Uygulamayı açın. İlk açılışta ev klasörünüz indekslenir.

Uygulama **ad-hoc imzalıdır**. macOS engellerse uygulamaya sağ tıkla **Aç**’ı
seçin ya da **Sistem Ayarları → Gizlilik ve Güvenlik** bölümünden bir kez onaylayın.
Kurulum sihirbazı veya arka plan servisi yoktur.

### 2. SwiftPM ile kaynaktan derleme

Denetlenebilir en doğrudan yöntem: repodaki kodu olduğu gibi derlersiniz.

```bash
git clone https://github.com/chnozmn-pixel/Needle.git
cd Needle
chmod +x scripts/*.sh
./scripts/build-app.sh
open dist/Needle.app
```

`scripts/build-app.sh` release derlemesi yapar, `.app` paketini oluşturur, simge
ve `Info.plist` dosyalarını kopyalar ve ad-hoc imzalar. Çıktı: `dist/Needle.app`.

### 3. Bu repodan Homebrew Cask

`Casks/needle.rb` dosyası bir Cask tanımı içerir. SHA-256 değeri her sürümde
`scripts/package-release.sh` çıktısından yenilenir. Cask bir tap’e yayınlandıktan
sonra:

```bash
brew tap chnozmn-pixel/needle
brew install --cask needle
```

Cask release ZIP’ini indirir, SHA-256 doğrulaması yapar, `Needle.app` uygulamasını
`/Applications` içine kurar ve kaldırma sırasında Needle’ın destek dosyalarını
temizleyen bir `zap` tanımı sağlar.

Yayınlamadan önce yerel deneme için:

```bash
brew install --cask ./Casks/needle.rb
```

### 4. Doğrudan çalıştırma — geliştirme

```bash
swift run Needle
```

Debug derlemesi oluşturur ve aynı indeks veritabanını kullanır. Normal kurulum
yolu değil, geliştirme içindir.

### Bakım: release ZIP oluşturma

```bash
./scripts/package-release.sh
# dist/Needle-0.1.0.zip ve SHA-256 değerini yazdırır
```

ZIP’i GitHub Release olarak yükleyin ve SHA-256 değerini Cask dosyasına kopyalayın.

## İlk açılış

- Needle ev klasörünüzü otomatik indeksler. Kökleri **Ayarlar → Kökler** bölümünden
  ekleyebilir/silebilirsiniz.
- Alt çubuk canlı tarama ilerlemesini ve kayıt sayısını gösterir.
- `⌘⇧Space` pencereyi öne getirir. `⏎` açar, `⌘⏎` Finder’da gösterir,
  `Space` Quick Look açar, `⌘⇧C` yolları kopyalar.
- Arayüz dili varsayılan olarak **İngilizce**’dir. Ayarlar’da sistem dili,
  Türkçe, Almanca, İspanyolca, Fransızca, İtalyanca, Portekizce, Japonca,
  Basitleştirilmiş Çince, Korece, Rusça, Arapça ve Hintçe bulunur. Dil değişimi
  anında uygulanır; çevrilmemiş metinler İngilizce’ye düşer.

## Arama sözdizimi

| Örnek | Anlamı |
| --- | --- |
| `report` | Adında “report” geçenler |
| `"annual report"` | Tam ifade |
| `apple \| pear` | VEYA |
| `<apple pear> \| banana` | Grup + VEYA |
| `!tmp` | “tmp” içerenleri hariç tut |
| `ext:pdf;docx` | PDF veya DOCX |
| `path:projects` | Tam yolda geçen |
| `file  size:>10mb` | 10 MB’dan büyük dosyalar |
| `dm:today` | Bugün değiştirilenler |
| `content:needle` | Dosya içeriğinde ara |
| `dupe:size;content` | Yinelenen dosyalar |
| `distinct:name` | Tekil sonuçlar |

Boşluk VE, `|` VEYA, `!` DEĞİL anlamına gelir. Tam liste uygulamada
**Ayarlar → Sözdizimi** sekmesindedir.

## Mimari

| Katman | Görev |
| --- | --- |
| `FileSystem.scan` | Seçilen kökleri POSIX `opendir`/`readdir`/`lstat` ile dolaşır, metadata alır ve SQLite’a yazar. |
| `IndexDatabase` | Kalıcı WAL modlu SQLite veritabanı; artımlı ekleme/güncelleme/silme. |
| `SearchEngine` | Bellek içi 1/2/3 bayt ters n-gram posting listeleri; aday kesişiminden sonra gerçek substring doğrulaması. |
| `FSEventsWatcher` | Yerel birimlerdeki canlı değişiklik akışı; sadece etkilenen kayıtlar güncellenir. |
| `SpotlightSearch` | Boşluklar ve ağ birimleri için isteğe bağlı `mdfind` tamamlaması. |
| `IndexStore` / `IndexCoordinator` | Tarama yaşam döngüsü, ağ zamanlaması ve SwiftUI için durum yayınlama. |
| `NeedleApp` | SwiftUI arayüzü, kısayollar, Quick Look, dışa aktarma ve ayarlar. |
| `LocalizationManager` | İngilizce’ye düşen çalışma zamanı dil değişimi. |

Kimlikler inode değil, normalize edilmiş tam yolun 64-bit FNV-1a özetidir; böylece
ağ paylaşımlarında da kararlı kalır.

## Kapsam

Var: kalıcı indeks, canlı arama, FSEvents, zamanlamalı ağ kökleri, Spotlight
zenginleştirme, Everything tarzı sorgu ayrıştırma, içerik ve yinelenen dosya
araması, sıralama, dışa aktarma, HTTP/JSON uç noktası, lokalizasyon ve yukarıdaki
arayüz özellikleri.

Henüz yok: ETP ikili protokolü, tam dosya listesi içe/dışa aktarma uyumu, indeks
günlüğü/özellik uyumu, gelişmiş indeks konumu ayarları ve özel sıralamanın son
ayrıntıları. Katkılar memnuniyetle karşılanır.

## Testler

```bash
swift test
```

Testler sorgu ayrıştırma, n-gram arama, artımlı indeks güncellemeleri, gelişmiş
sorgular, ağ zamanlaması, HTTP uç noktaları ve lokalizasyon denetimini kapsar.

## Lisans ve teşekkürler

Needle [MIT Lisansı](LICENSE) ile yayınlanır.

Kaynaklar ve teşekkürler ayrıca [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md)
dosyasındadır. Kısaca: arama dilini belgeleyen voidtools’a, platform altyapısı
için Apple ve SQLite projelerine ve test edip hata bildiren herkese teşekkürler.

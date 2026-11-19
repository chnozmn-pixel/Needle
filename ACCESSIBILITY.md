# Accessibility Statement / Erişilebilirlik Beyanı

**EN** — Needle is a native macOS 13+ SwiftUI app. We aim to make the core
search workflow usable with the keyboard and with macOS assistive technologies.
This statement describes what is supported today and what is still missing.

**TR** — Needle, macOS 13+ için yerel bir SwiftUI uygulamasıdır. Temel arama
akışının klavye ve macOS yardımcı teknolojileriyle kullanılabilir olmasını
hedefliyoruz. Bu belge şu an desteklenenleri ve henüz eksik olanları anlatır.

## Supported environment / Desteklenen ortam

- macOS 13 or newer, on Apple Silicon (`arm64`) and Intel (`x86_64`) Macs.
  / macOS 13 veya üzeri; Apple Silicon (`arm64`) ve Intel (`x86_64`) Mac'ler.
- English default UI with runtime language switching; strings fall back to
  English when a translation is missing. / Varsayılan İngilizce arayüz,
  çalışma anında dil değiştirme; çeviri eksikse İngilizceye geri dönülür.
- System light/dark appearance and the app's theme setting are respected via
  SwiftUI's `preferredColorScheme`. / Sistem açık/koyu görünümü ve uygulama
  teması SwiftUI `preferredColorScheme` ile uygulanır.

## What works today / Şu an çalışanlar

- The search field, buttons and standard controls are native SwiftUI/AppKit
  elements and participate in VoiceOver navigation and keyboard focus.
  / Arama alanı, düğmeler ve standart kontroller yerel SwiftUI/AppKit
  öğeleridir; VoiceOver gezintisine ve klavye odağına katılırlar.
- The result view and gallery provide explicit accessibility labels for the
  "no results" state and the view-mode switcher. / Sonuç görünümü ve galeri,
  "sonuç yok" durumu ile görünüm modu değiştirici için açık erişilebilirlik
  etiketleri sunar.
- Keyboard shortcuts are available for the main actions (see below).
  / Ana işlemler için klavye kısayolları mevcuttur (aşağıya bakın).

| Shortcut / Kısayol | Action / İşlev |
| --- | --- |
| `⌘F` | Focus the search field / Arama alanına odaklan |
| `⌥⌘F` | Advanced search / Gelişmiş arama |
| `Return` | Open selected item / Seçili öğeyi aç |
| `Space` | Quick Look / Hızlı Önizleme |
| `⌘Return` | Reveal in Finder / Finder'da göster |
| `⌘I` | Properties / Özellikler |
| `⇧⌘C` | Copy paths / Yolları kopyala |
| `⇧⌘E` | Export as CSV / CSV olarak dışa aktar |
| `⌘R` | Rescan / Yeniden tara |
| `⌘,` | Settings / Ayarlar |
| `⌘Q` | Quit / Çık |

Needle also registers a configurable global hotkey to show the window from
anywhere. / Needle, pencereyi her yerden göstermek için yapılandırılabilir bir
küresel kısayol da kaydeder.

## Known limitations / Bilinen sınırlamalar

- A full VoiceOver audit of the result table, sidebar and gallery has not been
  completed; some custom rows expose only their visible text.
  / Sonuç tablosu, kenar çubuğu ve galeri için tam bir VoiceOver denetimi
  yapılmadı; bazı özel satırlar yalnızca görünen metni sunar.
- There is no dedicated high-contrast theme beyond the system appearance.
  / Sistem görünümünün dışında özel bir yüksek kontrast teması yoktur.
- Dynamic Type size changes are not handled with dedicated layouts in the
  dense result table.
  / Yoğun sonuç tablosunda Dinamik Yazı boyutu değişiklikleri için özel düzen
  yoktur.
- The ETP and HTTP endpoints are developer/network features with no UI-level
  accessibility surface.
  / ETP ve HTTP uçları geliştirici/ağ özellikleridir; arayüz düzeyinde
  erişilebilirlik yüzeyi yoktur.

## Reporting a barrier / Engel bildirme

If an accessibility barrier prevents you from using Needle, open an issue using
the bug report template and include the macOS version, the assistive technology
and the exact steps that failed. Add the `accessibility` label if possible.
/ Bir erişilebilirlik engeli Needle'ı kullanmanızı önlüyorsa, hata bildirimi
şablonuyla bir issue açın; macOS sürümünü, yardımcı teknolojiyi ve başarısız
olan adımları yazın. Mümkünse `accessibility` etiketini ekleyin.

# Needle

Fast, private, local file search for macOS — inspired by voidtools Everything.

Needle builds **its own index**. It does not require an Everything installation,
a Windows machine, or a cloud service. Search results update while you type.

> Türkçe kısa özet: Needle, macOS için Everything benzeri yerel bir dosya arama
> uygulamasıdır. Kendi SQLite indeksini oluşturur, FSEvents ile yerel değişiklikleri
> anında yakalar, ağ birimlerini ayarlanabilir bir zamanlamada tarar ve varsayılan
> olarak İngilizce'arayüzle gelir.

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

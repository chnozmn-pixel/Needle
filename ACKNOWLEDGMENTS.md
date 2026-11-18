# Acknowledgments / Teşekkürler

Needle is an **independent** macOS application. It is inspired by the publicly
documented behavior of voidtools Everything; **no source code from Everything
was copied or linked**.

## References used

- **voidtools** — the public Everything documentation was used as a reference
  for search syntax, filters, macros, character entities and general search
  behavior. Thank you for documenting a genuinely useful search language.
- **Apple** — SwiftUI, AppKit, FSEvents, Spotlight (`mdfind`), Quick Look,
  SF Symbols, Carbon hotkey APIs and the macOS system SQLite library.
- **SQLite project** — the embedded database engine that stores Needle's
  persistent index.
- **Swift open-source community** — Swift Package Manager, XCTest and the
  broader Swift/macOS developer documentation and examples.

## Thanks

Teşekkürler to everyone who tested Needle and reported the issues that shaped
this release — especially the reports about language switching, network scan
scheduling, shortcut labels and theme options. Those reports directly led to
the full string audit and the runtime localization system.

Thank you for using and improving Needle.

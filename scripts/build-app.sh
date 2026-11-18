#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Release derlemesi"
swift build -c release

APP="$ROOT/dist/Needle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/Needle" "$APP/Contents/MacOS/Needle"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Needle.icns" "$APP/Contents/Resources/Needle.icns"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Hazır: $APP"
echo "Açmak için: open \"$APP\""

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
APP="$ROOT/dist/Needle.app"
ZIP="$ROOT/dist/Needle-${VERSION}.zip"

echo "==> Release app: $VERSION"
"$ROOT/scripts/build-app.sh"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Release zip hazır: $ZIP"
shasum -a 256 "$ZIP"

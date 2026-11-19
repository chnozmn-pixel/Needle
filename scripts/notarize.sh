#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
APP="$ROOT/dist/Needle.app"
ZIP="$ROOT/dist/Needle-${VERSION}.zip"
PROFILE="${NOTARY_PROFILE:-needle-notary}"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "SIGN_IDENTITY gerekli. Örnek:" >&2
  echo "  export SIGN_IDENTITY='Developer ID Application: Ad Soyad (TEAMID)'" >&2
  exit 1
fi

echo "==> İmzalı release derlemesi: $VERSION"
SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/scripts/build-app.sh"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Notary servisine gönderiliyor (profil: $PROFILE)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Ticket uygulanıyor"
xcrun stapler staple "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Noterleşmiş ZIP hazır: $ZIP"
shasum -a 256 "$ZIP"

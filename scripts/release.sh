#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.1.0}"
BUILD="${2:-1}"
NOTARIZE="${NOTARIZE:-1}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: BOIS CLUB GAMES LLC (2239U5J89G)}"
TEAM="${TEAM_ID:-2239U5J89G}"
CI_DIR="${POKEMON_CI_DIR:-$HOME/.config/pokemon-ci}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist"
DD="${DERIVED_DATA:-$ROOT/build/ReleaseData}"

cd "$ROOT"
rm -rf "$OUT" "$DD"/Build/Products/Release/*.app "$DD"/Build/Products/Release/*.xpc "$DD"/Build/Products/Release/*.bundle && mkdir -p "$OUT" "$ROOT/build"
xcodegen generate

xcodebuild -project BetterFinder.xcodeproj -scheme BetterFinder -configuration Release \
  -derivedDataPath "$DD" ARCHS=arm64 \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build > "$ROOT/build/release.log" 2>&1 || { grep -E "error:" "$ROOT/build/release.log" | sort -u; echo "release build failed"; exit 1; }

APP="$DD/Build/Products/Release/betterfinder.app"
[ -d "$APP" ] || { echo "app not built"; exit 1; }
cp -R "$APP" "$OUT/"
APP="$OUT/betterfinder.app"

for bin in "$APP/Contents/MacOS/BetterFinderIndexer" "$APP/Contents/MacOS/betterfinder-mod"; do
  [ -f "$bin" ] && codesign --force --timestamp --options runtime --sign "$IDENTITY" "$bin"
done
for svc in BetterFinderModHost BetterFinderModCheck; do
  xpc="$APP/Contents/XPCServices/$svc.xpc"
  [ -d "$xpc" ] && codesign --force --timestamp --options runtime --sign "$IDENTITY" \
    --entitlements "BetterFinderModHost/$svc.entitlements" "$xpc"
done
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
  --entitlements BetterFinder/BetterFinder.entitlements "$APP"
if codesign -d --entitlements :- "$APP/Contents/XPCServices/"*.xpc 2>/dev/null | grep -q get-task-allow; then
  echo "get-task-allow still present"; exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="$OUT/betterfinder-$VERSION-macos.zip"
DMG="$OUT/betterfinder-$VERSION.dmg"

if [ "$NOTARIZE" = "1" ]; then
  set -a; . "$CI_DIR/notary.env"; set +a
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait --output-format json > "$ROOT/build/notary.json"
  if ! grep -q '"status" *: *"Accepted"' "$ROOT/build/notary.json"; then
    sub=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$ROOT/build/notary.json" | head -1)
    xcrun notarytool log "$sub" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" || true
    echo "notarization rejected"; exit 1
  fi
  xcrun stapler staple "$APP"
fi

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "betterfinder" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
if [ "$NOTARIZE" = "1" ]; then
  xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
  xcrun stapler staple "$DMG"
fi

ls -lh "$OUT"

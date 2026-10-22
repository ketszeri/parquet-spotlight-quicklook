#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_PATH="$ROOT_DIR/build/Parquet Quick Look and Index.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "FAIL: missing $APP_PATH (run ./scripts/build.sh first)" >&2
  exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT_DIR/preview/app/Info.plist")"
RELEASE_DIR="$ROOT_DIR/release"
STAGING_DIR="$RELEASE_DIR/Parquet-Spotlight-$VERSION"
DMG_PATH="$RELEASE_DIR/Parquet-Spotlight-$VERSION.dmg"
ZIP_PATH="$RELEASE_DIR/Parquet-Spotlight-$VERSION.zip"
SHA_PATH="$DMG_PATH.sha256"

rm -rf "$STAGING_DIR" "$DMG_PATH" "$ZIP_PATH" "$SHA_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"
if [[ -f "$ROOT_DIR/build/size-report.txt" ]]; then
  cp "$ROOT_DIR/build/size-report.txt" "$RELEASE_DIR/size-report.txt"
fi

(
  cd "$RELEASE_DIR"
  zip -r -y "$(basename "$ZIP_PATH")" "$(basename "$STAGING_DIR")" >/dev/null
)

hdiutil create \
  -volname "Parquet Spotlight $VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

shasum -a 256 "$DMG_PATH" > "$SHA_PATH"
echo "Packaged $DMG_PATH"
echo "Packaged $ZIP_PATH"

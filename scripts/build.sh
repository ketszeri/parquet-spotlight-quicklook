#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"

# Spotlight importer bundle
MD_BUNDLE_DIR="$BUILD_DIR/Parquet.mdimporter"
MD_MACOS_DIR="$MD_BUNDLE_DIR/Contents/MacOS"
MD_RESOURCES_DIR="$MD_BUNDLE_DIR/Contents/Resources"

# Modern Quick Look preview extension hosted in app bundle
APP_BUNDLE_DIR="$BUILD_DIR/Parquet Quick Look and Index.app"
APP_CONTENTS_DIR="$APP_BUNDLE_DIR/Contents"
APP_MACOS_DIR="$APP_CONTENTS_DIR/MacOS"
APP_PLUGINS_DIR="$APP_CONTENTS_DIR/PlugIns"
APP_RESOURCES_DIR="$APP_CONTENTS_DIR/Resources"

APPEX_DIR="$APP_PLUGINS_DIR/ParquetQuickLook.appex"
APPEX_CONTENTS_DIR="$APPEX_DIR/Contents"
APPEX_MACOS_DIR="$APPEX_CONTENTS_DIR/MacOS"

LEGACY_APP_BUNDLE_DIR="$BUILD_DIR/ParquetPreviewHost.app"
LEGACY_QUICKVIEW_APP_BUNDLE_DIR="$BUILD_DIR/Parquet QuickView and Index.app"
LEGACY_QLGEN_DIR="$BUILD_DIR/Parquet.qlgenerator"

rm -rf "$MD_BUNDLE_DIR" "$APP_BUNDLE_DIR" "$LEGACY_APP_BUNDLE_DIR" "$LEGACY_QUICKVIEW_APP_BUNDLE_DIR" "$LEGACY_QLGEN_DIR"
mkdir -p "$MD_MACOS_DIR" "$MD_RESOURCES_DIR" "$APP_MACOS_DIR" "$APP_RESOURCES_DIR" "$APPEX_MACOS_DIR"

SDK_PATH="$(xcrun --show-sdk-path)"
SWIFT_MODULE_CACHE="$BUILD_DIR/swift-module-cache"
mkdir -p "$SWIFT_MODULE_CACHE"

sanitize_bundle() {
  local bundle_path="$1"
  xattr -cr "$bundle_path" >/dev/null 2>&1 || true
  # Some environments keep re-introducing these attributes on bundles in synced folders.
  for attr in com.apple.FinderInfo "com.apple.fileprovider.fpfs#P" com.apple.macl com.apple.provenance; do
    find "$bundle_path" -exec xattr -d "$attr" {} + >/dev/null 2>&1 || true
  done
}

sign_with_retry() {
  local target="$1"
  shift
  local attempts=0
  until codesign "$@" "$target"; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 3 ]]; then
      echo "FAIL: codesign failed for $target after $attempts attempts" >&2
      return 1
    fi
    sanitize_bundle "$target"
    sleep 0.2
  done
}

# Build metadata importer
clang \
  -isysroot "$SDK_PATH" \
  -F"$SDK_PATH/System/Library/Frameworks/CoreServices.framework/Frameworks" \
  -mmacosx-version-min=12.0 \
  -Wall -Wextra -Werror \
  -O2 \
  -bundle \
  "$ROOT_DIR/src/MetadataImporter.c" \
  -framework CoreFoundation \
  -framework CoreServices \
  -o "$MD_MACOS_DIR/ParquetImporter"

cp "$ROOT_DIR/plist/Info.plist" "$MD_BUNDLE_DIR/Contents/Info.plist"
cp "$ROOT_DIR/resources/schema.xml" "$MD_RESOURCES_DIR/schema.xml"

# Build host app with GUI manager (install/repair/uninstall/settings)
swiftc \
  -parse-as-library \
  -module-name ParquetQuickLookAndIndex \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -O \
  "$ROOT_DIR"/Sources/ParquetCore/*.swift \
  "$ROOT_DIR"/preview/shared/*.swift \
  "$ROOT_DIR/preview/app/ExcelSave.swift" \
  "$ROOT_DIR/preview/app/AppMain.swift" \
  -framework AppKit \
  -framework Foundation \
  -framework SwiftUI \
  -framework UniformTypeIdentifiers \
  -o "$APP_MACOS_DIR/ParquetQuickLookAndIndex"

cp "$ROOT_DIR/preview/app/Info.plist" "$APP_CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/preview/app/AppIcon.icns" "$APP_RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/NEWS.md" "$APP_RESOURCES_DIR/NEWS.md"
cp -R "$MD_BUNDLE_DIR" "$APP_RESOURCES_DIR/Parquet.mdimporter"

# Build extension entry point object (NSExtensionMain)
clang \
  -isysroot "$SDK_PATH" \
  -mmacosx-version-min=12.0 \
  -Wall -Wextra -Werror \
  -O2 \
  -c "$ROOT_DIR/preview/extension/NSExtensionMain.m" \
  -o "$BUILD_DIR/NSExtensionMain.o"

clang \
  -isysroot "$SDK_PATH" \
  -mmacosx-version-min=12.0 \
  -Wall -Wextra -Werror \
  -O2 \
  -c "$ROOT_DIR/preview/extension/PreviewException.m" \
  -o "$BUILD_DIR/PreviewException.o"

clang \
  -isysroot "$SDK_PATH" \
  -mmacosx-version-min=12.0 \
  -Wall -Wextra -Werror \
  -O2 \
  -c "$ROOT_DIR/preview/extension/KeepPrincipal.m" \
  -o "$BUILD_DIR/KeepPrincipal.o"

# Row decoding is linked only into the Quick Look extension.
if ! command -v cargo >/dev/null 2>&1; then
  echo "FAIL: cargo is required to build Quick Look row preview (install Rust from https://rustup.rs)" >&2
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=12.0
export CARGO_TARGET_DIR="$BUILD_DIR/native-target"
NATIVE_MANIFEST="$ROOT_DIR/native/parquet_preview/Cargo.toml"
case "$(uname -m)" in
  arm64) RUST_HOST_TARGET="aarch64-apple-darwin" ;;
  x86_64) RUST_HOST_TARGET="x86_64-apple-darwin" ;;
  *)
    echo "FAIL: unsupported architecture $(uname -m)" >&2
    exit 1
    ;;
esac
if [[ "$RUST_HOST_TARGET" == "aarch64-apple-darwin" ]]; then
  RUST_OTHER_TARGET="x86_64-apple-darwin"
else
  RUST_OTHER_TARGET="aarch64-apple-darwin"
fi
# Host build lands in $CARGO_TARGET_DIR/release so `cargo test --release` reuses it.
cargo build --release --locked --manifest-path "$NATIVE_MANIFEST" --lib
HOST_PREVIEW_LIB="$CARGO_TARGET_DIR/release/libparquet_preview.a"
ROW_PREVIEW_LIB="$BUILD_DIR/libparquet_preview.a"
RUST_TARGETS="$RUST_HOST_TARGET"
if rustup target add "$RUST_OTHER_TARGET" >/dev/null 2>&1 \
  && cargo build --release --locked --manifest-path "$NATIVE_MANIFEST" --target "$RUST_OTHER_TARGET" --lib; then
  OTHER_PREVIEW_LIB="$CARGO_TARGET_DIR/$RUST_OTHER_TARGET/release/libparquet_preview.a"
  lipo -create "$HOST_PREVIEW_LIB" "$OTHER_PREVIEW_LIB" -output "$ROW_PREVIEW_LIB"
  RUST_TARGETS="$RUST_HOST_TARGET,$RUST_OTHER_TARGET"
  echo "Linked universal row-preview library"
else
  echo "note: row preview built for $RUST_HOST_TARGET only"
  cp "$HOST_PREVIEW_LIB" "$ROW_PREVIEW_LIB"
fi

# Build modern Quick Look preview extension executable
swiftc \
  -parse-as-library \
  -module-name ParquetQuickLookExtension \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -O \
  -import-objc-header "$ROOT_DIR/preview/extension/ParquetPreview.h" \
  "$ROOT_DIR"/preview/shared/*.swift \
  "$ROOT_DIR/preview/extension/PreviewProvider.swift" \
  "$ROOT_DIR/preview/extension/PreviewLog.swift" \
  "$ROOT_DIR/preview/extension/RowPreview.swift" \
  "$ROOT_DIR/preview/extension/FilterFieldLayout.swift" \
  "$ROOT_DIR/preview/extension/StatsDecoder.swift" \
  "$ROOT_DIR/preview/extension/StatsPanel.swift" \
  "$ROOT_DIR/preview/extension/ExcelExport.swift" \
  "$ROOT_DIR/preview/extension/ParquetPreviewController.swift" \
  "$BUILD_DIR/NSExtensionMain.o" \
  "$BUILD_DIR/PreviewException.o" \
  "$BUILD_DIR/KeepPrincipal.o" \
  "$ROW_PREVIEW_LIB" \
  -framework AppKit \
  -framework Foundation \
  -framework QuickLookUI \
  -framework UniformTypeIdentifiers \
  -framework CoreFoundation \
  -framework Security \
  -framework SystemConfiguration \
  -liconv \
  -lresolv \
  -o "$APPEX_MACOS_DIR/ParquetQuickLookExtension"

mkdir -p "$APP_RESOURCES_DIR/Licenses"
cp "$ROOT_DIR/licenses/apache-arrow-LICENSE.txt" "$APP_RESOURCES_DIR/Licenses/apache-arrow-LICENSE.txt"
cp "$ROOT_DIR/licenses/apache-arrow-NOTICE.txt" "$APP_RESOURCES_DIR/Licenses/apache-arrow-NOTICE.txt"
cp "$ROOT_DIR/licenses/rust_xlsxwriter-LICENSE-MIT.txt" "$APP_RESOURCES_DIR/Licenses/rust_xlsxwriter-LICENSE-MIT.txt"
cp "$ROOT_DIR/licenses/rust_xlsxwriter-LICENSE-Apache-2.0.txt" "$APP_RESOURCES_DIR/Licenses/rust_xlsxwriter-LICENSE-Apache-2.0.txt"
cp "$ROOT_DIR/LICENSE" "$APP_RESOURCES_DIR/Licenses/MIT-LICENSE.txt"

STATIC_BYTES="$(stat -f%z "$ROW_PREVIEW_LIB")"
APPEX_BYTES="$(stat -f%z "$APPEX_MACOS_DIR/ParquetQuickLookExtension")"
IMPORTER_BYTES="$(stat -f%z "$MD_MACOS_DIR/ParquetImporter")"
XLSX_SYMBOL_BYTES=0
STATS_SYMBOL_BYTES=0
if nm -print-size "$ROW_PREVIEW_LIB" > "$BUILD_DIR/nm-preview.txt" 2>/dev/null; then
  XLSX_SYMBOL_BYTES="$(python3 - "$BUILD_DIR/nm-preview.txt" xlsx <<'PY'
import sys
total = 0
pattern = sys.argv[2].lower()
for line in open(sys.argv[1], errors="replace"):
    parts = line.split()
    if len(parts) < 4:
        continue
    size, name = parts[1], parts[-1].lower()
    if pattern not in name:
        continue
    if not all(c in "0123456789abcdefABCDEF" for c in size):
        continue
    total += int(size, 16)
print(total)
PY
)" || XLSX_SYMBOL_BYTES=0
  STATS_SYMBOL_BYTES="$(python3 - "$BUILD_DIR/nm-preview.txt" 'stats|detect' <<'PY'
import sys
total = 0
patterns = sys.argv[2].lower().split("|")
for line in open(sys.argv[1], errors="replace"):
    parts = line.split()
    if len(parts) < 4:
        continue
    size, name = parts[1], parts[-1].lower()
    if not any(pattern in name for pattern in patterns):
        continue
    if "xlsx" in name:
        continue
    if not all(c in "0123456789abcdefABCDEF" for c in size):
        continue
    total += int(size, 16)
print(total)
PY
)" || STATS_SYMBOL_BYTES=0
fi
cat > "$BUILD_DIR/size-report.txt" <<EOF
staticlib_bytes=$STATIC_BYTES
appex_executable_bytes=$APPEX_BYTES
importer_executable_bytes=$IMPORTER_BYTES
xlsx_symbol_bytes=$XLSX_SYMBOL_BYTES
stats_symbol_bytes=$STATS_SYMBOL_BYTES
rust_targets=$RUST_TARGETS
EOF
echo "Row preview static library: $STATIC_BYTES bytes"
echo "Quick Look extension executable: $APPEX_BYTES bytes"
echo "Spotlight importer executable: $IMPORTER_BYTES bytes"

cp "$ROOT_DIR/preview/extension/Info.plist" "$APPEX_CONTENTS_DIR/Info.plist"

# Sign bundles
sanitize_bundle "$MD_BUNDLE_DIR"
sign_with_retry "$MD_BUNDLE_DIR" -s - -f --deep --timestamp=none
sanitize_bundle "$APP_BUNDLE_DIR"
sign_with_retry "$APPEX_DIR" -s - -f \
  --timestamp=none \
  --entitlements "$ROOT_DIR/preview/extension/Entitlements.plist"
# Signing the nested appex may reintroduce metadata; scrub again before outer app sign.
sanitize_bundle "$APP_BUNDLE_DIR"
sign_with_retry "$APP_BUNDLE_DIR" -s - -f \
  --timestamp=none \
  --entitlements "$ROOT_DIR/preview/app/Entitlements.plist"

echo "Built: $MD_BUNDLE_DIR"
echo "Built: $APP_BUNDLE_DIR (contains modern Quick Look extension)"

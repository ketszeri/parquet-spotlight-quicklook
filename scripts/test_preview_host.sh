#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
SDK_PATH="$(xcrun --show-sdk-path)"
LIB="$BUILD_DIR/libparquet_preview.a"
FIXTURE="$ROOT_DIR/fixtures/parquet/snappy.parquet"
BUNDLE_DIR="$BUILD_DIR/ParquetPreviewTest.bundle"
BUNDLE_MACOS="$BUNDLE_DIR/Contents/MacOS"
HOST="$BUILD_DIR/preview-host"
APPEX="$BUILD_DIR/Parquet Quick Look and Index.app/Contents/PlugIns/ParquetQuickLook.appex"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$LIB" ]] || fail "missing $LIB; run scripts/build.sh first"
[[ -f "$FIXTURE" ]] || fail "missing fixture $FIXTURE"
[[ -d "$APPEX" ]] || fail "missing appex; run scripts/build.sh first"

principal="$(plutil -extract NSExtension.NSExtensionPrincipalClass raw "$APPEX/Contents/Info.plist")"
[[ "$principal" == "ParquetPreviewController" ]] || fail "principal class is '$principal'"
data_based="$(plutil -extract NSExtension.NSExtensionAttributes.QLIsDataBasedPreview raw "$APPEX/Contents/Info.plist")"
[[ "$data_based" == "false" ]] || fail "QLIsDataBasedPreview should be false for the view host"

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
  -c "$ROOT_DIR/Tests/preview_host_glue.m" \
  -o "$BUILD_DIR/preview_host_glue.o"

clang \
  -isysroot "$SDK_PATH" \
  -mmacosx-version-min=12.0 \
  -Wall -Wextra -Werror \
  -O2 \
  -c "$ROOT_DIR/preview/extension/KeepPrincipal.m" \
  -o "$BUILD_DIR/KeepPrincipal.o"

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_MACOS"
cat > "$BUNDLE_DIR/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>ParquetPreview</string>
  <key>CFBundleIdentifier</key>
  <string>com.rkrug.parquetindexer.previewhost.preview.test</string>
  <key>CFBundleName</key>
  <string>ParquetPreview</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>NSPrincipalClass</key>
  <string>ParquetPreviewController</string>
</dict>
</plist>
EOF

swiftc \
  -parse-as-library \
  -module-name ParquetQuickLookExtension \
  -O \
  -import-objc-header "$ROOT_DIR/preview/extension/ParquetPreview.h" \
  "$ROOT_DIR"/preview/shared/*.swift \
  "$ROOT_DIR/preview/extension/PreviewProvider.swift" \
  "$ROOT_DIR/preview/extension/PreviewLog.swift" \
  "$ROOT_DIR/preview/extension/RowPreview.swift" \
  "$ROOT_DIR/preview/extension/ParquetPreviewController.swift" \
  "$BUILD_DIR/PreviewException.o" \
  "$BUILD_DIR/KeepPrincipal.o" \
  "$LIB" \
  -Xlinker -bundle \
  -framework AppKit \
  -framework Foundation \
  -framework QuickLookUI \
  -framework UniformTypeIdentifiers \
  -framework CoreFoundation \
  -framework Security \
  -framework SystemConfiguration \
  -liconv \
  -lresolv \
  -o "$BUNDLE_MACOS/ParquetPreview"

codesign -s - -f --timestamp=none "$BUNDLE_DIR"

swiftc \
  -O \
  -import-objc-header "$ROOT_DIR/preview/extension/ParquetPreview.h" \
  "$ROOT_DIR/Tests/preview_host.swift" \
  "$BUILD_DIR/PreviewException.o" \
  "$BUILD_DIR/preview_host_glue.o" \
  -framework AppKit \
  -framework Foundation \
  -framework QuickLookUI \
  -o "$HOST"
codesign -s - -f --timestamp=none "$HOST"

export PARQUET_PREVIEW_LOG=1
HOME_ROWS="$(mktemp -d)"
HOME_OFF="$(mktemp -d)"
mkdir -p "$HOME_OFF/Library/Application Support/ParquetPreview"
cat > "$HOME_OFF/Library/Application Support/ParquetPreview/settings.json" <<'EOF'
{
  "expandDepth": 1,
  "showAllColumns": true,
  "maxColumns": 500,
  "showPhysicalType": false,
  "hideListElement": true,
  "scanAllFiles": false,
  "maxScanFiles": 500,
  "recursiveScan": true,
  "showRowPreview": false,
  "previewRows": false,
  "maxPreviewRows": 100,
  "maxPreviewColumns": 50
}
EOF

echo "==> Host the view controller for a real fixture"
PARQUET_PROBE_APPEX="$APPEX" \
  HOME="$HOME_ROWS" \
  "$HOST" "$BUNDLE_DIR" "$FIXTURE" rows

echo "==> Host the view controller with row preview switched off"
HOME="$HOME_OFF" \
  "$HOST" "$BUNDLE_DIR" "$FIXTURE" schema-only

echo "PASS: preview host"

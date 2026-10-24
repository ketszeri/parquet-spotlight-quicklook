#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/tests"
BIN="$OUT_DIR/core_tests"
SWIFT_MODULE_CACHE="$ROOT_DIR/build/swift-module-cache"
SDK_PATH="$(xcrun --show-sdk-path)"

mkdir -p "$OUT_DIR"
mkdir -p "$SWIFT_MODULE_CACHE"

# PARQUET_COVERAGE is set by the fork's Sonar job. Normal CI keeps -O.
typeset -a swift_opt
swift_opt=(-O)
if [[ "${PARQUET_COVERAGE:-}" == "1" ]]; then
  swift_opt=(-profile-generate -profile-coverage-mapping)
fi

xcrun swiftc \
  -module-cache-path "$SWIFT_MODULE_CACHE" \
  -sdk "$SDK_PATH" \
  "${swift_opt[@]}" \
  "$ROOT_DIR"/Sources/ParquetCore/*.swift \
  "$ROOT_DIR"/preview/shared/*.swift \
  "$ROOT_DIR/preview/app/ExcelSave.swift" \
  "$ROOT_DIR/Tests/core_tests.swift" \
  "$ROOT_DIR/Tests/row_preview_logic_tests.swift" \
  "$ROOT_DIR/Tests/excel_save_tests.swift" \
  -framework AppKit \
  -framework UniformTypeIdentifiers \
  -o "$BIN"

"$BIN"

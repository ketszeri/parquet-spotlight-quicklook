#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v cargo >/dev/null 2>&1; then
  echo "FAIL: cargo is required to test row preview" >&2
  exit 1
fi

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT_DIR/build/native-target}"
# Release matches the library linked into the Quick Look extension.
cargo test --release --manifest-path "$ROOT_DIR/native/parquet_preview/Cargo.toml" --locked -- --test-threads=8

# Contributing

## Development Setup

Prerequisites:

- macOS 12 or newer
- Xcode Command Line Tools (`xcrun`, `clang`, `swiftc`, `codesign`)
- Rust stable via rustup (`cargo`, 1.88 or newer) for the Quick Look row decoder in `native/parquet_preview`

Build:

```bash
./scripts/build.sh
```

Install locally:

```bash
./scripts/install.sh
```

## Verify Changes

Use a sample parquet file:

```bash
mdimport -t -d2 /path/to/file.parquet
mdls -name com_rkrug_parquet_is_valid \
     -name com_rkrug_parquet_footer_length \
     -name com_rkrug_parquet_file_size \
     /path/to/file.parquet
```

## Code Style

- Keep the Spotlight importer metadata-only. It reads the Parquet footer and does not decode row pages.
- Row decoding belongs only in the Quick Look extension, behind `native/parquet_preview`. Do not hand-roll a page decoder. Keep the byte, row, column, memory, and wall-time caps, and keep the schema fallback.
- Keep the footer parser in `PreviewProvider.swift` stable. New Quick Look behavior goes in `preview/extension/ParquetPreviewController.swift` and `preview/shared/`.
- `RowPreviewDefaults.showsRowPreviewByDefault` is the opt-in switch. This fork leaves it `true`. Upstream sets it to `false`.
- Prefer small, focused changes.
- Keep documentation up to date with behavior changes.


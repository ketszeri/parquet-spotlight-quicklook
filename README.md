# parquet_indexer (Spotlight Importer for `.parquet`)

This is [Csaba Kétszeri's fork](https://github.com/ketszeri/parquet-spotlight-quicklook) (`0.5.0-ketszeri.5`) of [rkrug/parquet-spotlight-quicklook](https://github.com/rkrug/parquet-spotlight-quicklook). The original project is by [rkrug](https://github.com/rkrug). This fork adds Quick Look row preview, a Stats view, and Excel export, and keeps the MIT license. See [LICENSE](LICENSE). The in-app update check looks at this fork's GitHub releases, not upstream.

> [!WARNING]
> **This repository was written completely using Codex.**
> **Model:** GPT-5 (Codex coding agent)
> **Version:** Codex GPT-5 session build (2026-03-12)
> It works for me, but I take no guarantee if it works for you.

This project provides:

- a macOS Spotlight importer (`.mdimporter`) for Parquet metadata indexing
- a modern Quick Look preview extension (`.appex`, embedded in a host app) for Parquet metadata preview with:
  - a **Rows** tab (first N rows, default 100) next to the schema
  - hierarchical schema tree (collapsible groups)
  - full parsed column list (no preview truncation of the schema)
  - Arrow-style logical scalar type labels where available
- a small GUI manager app (`Parquet Quick Look and Index.app`) with:
  - `Re-Install`, `Repair Registration`, and `Uninstall` actions
  - `Copy Diagnostic Report` action for support/issue reports (anonymized)
  - Quick Look rendering settings (schema display, dataset scan, and row preview)
  - dedicated `Updates` tab for release checks (`Daily`/`Weekly`/`Monthly`)
  - automatic importer install on app launch if missing

Since `0.3.0`, naming is standardized to Apple's official **Quick Look** terminology.

The Spotlight importer reads only Parquet footer metadata (`...<metadata_len><PAR1>`), does not parse row contents, and writes Spotlight metadata for search. Row decoding happens only in the Quick Look extension, and only when **Show row preview** is on. That default is `RowPreviewDefaults.showsRowPreviewByDefault`.

## Row preview

Press Space on a `.parquet` file in Finder. The preview opens on a **Rows** tab with a table of the first rows, and a **Schema** tab with the existing metadata view. A folder dataset previews rows from the first readable file in that scan (lexicographically smallest valid path).

The table:

- truncates long values and keeps the longer text in the cell tooltip
- renders nested structs, lists, and maps on one line
- shows nulls as `null`
- shows at most 50 columns and says how many were hidden
- fills the preview when the window is resized, and scrolls in both directions with the header kept visible
- sorts when a column header is clicked (ascending, descending, then off). Numbers and decimals sort numerically, dates and timestamps sort in time order, other values sort as text, and nulls stay last
- filters from the search field and from the field under each column. Each column field uses that column's x and width, and follows a resize, reorder, or horizontal scroll. Filtering and sorting use the rows already loaded

The window size follows the visible frame of the screen Finder is on, minus a margin. A wide table uses that width. A narrow or short table stays compact. Quick Look does not report the destination screen, so the extension uses `NSScreen.main` when that call succeeds. If there is no screen, or the size is not a real display, the window is clamped between 420×280 and 4096×4096.

The manager app's Quick Look settings include **Show row preview** and a row-count popup (`10`, `50`, `100`, `500`, `1000`). The same popup is in the preview. The default is the single constant `RowPreviewDefaults.showsRowPreviewByDefault` in `preview/shared/RowPreviewDefaults.swift`. This fork sets it to `true`. Upstream should set it to `false` so the schema-only preview stays the default until a user opts in. Turn the toggle off and Quick Look shows the schema only; the row decoder is not called.

The extension is sandboxed and has no network entitlement. Row values stay in the Quick Look process. They are not written to the Spotlight index.

The rows UI is an AppKit table inside a view-based `QLPreviewingController`. A data-based HTML reply does not run JavaScript in Finder, and `WKWebView` needs `com.apple.security.network.client` for its web process, which this extension does not request. Sort, filter, and the row popup are native controls. The schema tab is an outline of the same footer metadata. The view is created in `loadView` and is not replaced afterwards. An exception while building the preview is caught, logged, and turned into a schema fallback; if that also fails, Quick Look receives the error. Stages are written with `os_log` subsystem `com.rkrug.parquetindexer`, category `preview`.

The extension reads row-preview settings from `settings.json` in its container and from `UserDefaults(suiteName: "group.com.rkrug.parquetindexer")`. It does not use its own bundle identifier as a defaults suite, and it does not call Core Spotlight. The Spotlight importer remains footer-only.

Decoding uses Apache Arrow's Rust [`parquet`](https://crates.io/crates/parquet) crate (arrow-rs 60, Apache-2.0) through a small C ABI, `libparquet_preview.a`, linked only into the Quick Look extension. See [Decoder choice](#decoder-choice) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Any decode error or timeout leaves the schema view in place and shows a short banner. Finder is not asked to wait past the decoder's 2 second cap. The note `Showing N of M rows` appears when the table is shorter than the file, including when a filter or the row popup hides part of what was loaded.

Privacy: the Spotlight importer never reads row pages. Row bytes are decoded only after the user leaves **Show row preview** on, only inside the Quick Look extension, and only up to the caps below. The extension has no network entitlement, so the preview cannot upload the file.

### Decoder choice

| Candidate | Why it was not linked into the extension |
| --- | --- |
| DuckDB | Maintained and convenient, but the embedded library is large and its runtime uses threads and temporary files that are a poor fit for a sandboxed Quick Look process. |
| Apache Arrow C++ | The reference C++ library. It is maintained and Apache-2.0, and it is also a very large, slow-to-build dependency for a preview of 100 rows. |
| arrow-rs `parquet` via a C ABI | Chosen. The `parquet` crate is the maintained Arrow implementation, Apache-2.0 (compatible with this MIT project when its LICENSE and NOTICE ship with the app), and it builds as a static library with only the codecs this preview needs. Rust's macOS 12 deployment target is supported. |

The crate is built with default features off. Enabled codecs are Snappy, ZSTD, GZIP (pure Rust `flate2`/`zlib-rs`), and LZ4 (`lz4_flex`, raw). Uncompressed pages and dictionary and plain encodings come from the core reader. There is no `object_store`, async runtime, network stack, or encryption module.

Hard caps, enforced in the Rust library and mirrored by the Swift caller:

- 100 rows by default, chosen from 10, 50, 100, 500, or 1000 (hard maximum 1000)
- 50 columns maximum
- 32 MiB of file bytes read
- 2 seconds of wall time, after which the worker is cancelled
- 8 MiB uncompressed for one page, 64 MiB uncompressed across the read

A page header that claims a huge uncompressed size is rejected before the official decoder allocates it. Encrypted files and external column paths fail closed. A malformed file falls back to the schema view.

## Stats view

The preview's segmented control is **Rows / Schema / Stats**. Stats is available even when **Show row preview** is off. Choosing it does not change the Spotlight importer, which stays footer-only.

Each column is one row: storage type, count, nulls with a percent, distinct count, min, max, mean, median, sample standard deviation, 25th and 75th percentiles, and the most common values for text. Percentiles use linear interpolation on the scanned values (`p * (n - 1)`). The standard deviation divides by `n - 1`.

Parquet footer statistics supply whole-file min, max, and null count when every row group has them and the column is a single leaf. Mean, median, distinct, percentiles, and top values come from a streaming scan. The scan stops at 8 seconds, 256 MiB of bytes read, or 256 columns. If it stops early, the note says the other stats are based on the first N of M rows. Min and max from the footer stay whole-file. The scan runs off the main thread and is cancelled when the preview is released.

### Stringly typed columns

String and binary columns are inspected value by value. Empty and null cells are ignored. A type is chosen when at least 95% of the remaining values parse, using this order when more than one type qualifies: UUID, timestamp, date, decimal, integer, boolean. `0` and `1` stay integers. `true`/`false`/`yes`/`no` become booleans. Decimals accept both `.` and `,` as the decimal separator. A single separator is a decimal point (`1.234` is one and 234 thousandths, `1,50` is one and a half). Thousands separators need at least two groups (`1.234.567`, `1,234.50`, `1.234,50`). Dates accept `YYYY-MM-DD`, `DD.MM.YYYY`, `YYYY.MM.DD` with an optional trailing dot, and `MM/DD/YYYY`. A time (`HH:MM` or `HH:MM:SS`, optional fraction and `Z` or numeric offset, separated by `T` or a space) makes the value a timestamp. UUIDs are the hyphenated 8-4-4-4-12 form. The type line reads `string → int (98.7% parsed)`, and numeric or temporal stats use the parsed values. The unparsed count is the rest.

Temporal min, max, mean, median, and percentiles are shown as dates or timestamps. Their standard deviation is a number of seconds.

## Save as Excel

The preview's **Excel** menu has two commands.

**Entire file…** streams the Parquet file through the same decoder, one batch at a time, and writes `.xlsx` in constant memory (`rust_xlsxwriter` with the `constant_memory` feature). Numbers, booleans, dates, and timestamps are typed cells. Other values are strings. The header row is bold, the header stays frozen, and each sheet has an autofilter. This path does not use the row-preview caps (2 seconds, 32 MiB, 1000 rows). A progress panel counts rows, and Cancel stops the write between rows.

**Rows view…** writes the rows currently on screen: the active sort, filters, row count, and visible columns in their current order. It does not read the file again.

Excel allows 1,048,576 rows and 16,384 columns on a sheet. One row is the header, so each sheet holds 1,048,575 data rows. A longer file is split across sheets named `Rows`, `Rows 2`, and so on. Columns past 16,384 are left out. The preview says so before writing and continues only after you confirm.

A text cell whose trimmed value starts with `=`, `+`, `-`, or `@` is prefixed with `'`, so Excel does not open it as a formula. Typed numbers, booleans, and dates are not prefixed. Integers whose magnitude is above 2^53 are written as text so the spreadsheet does not round them.

The Quick Look extension is sandboxed with `files.user-selected.read-only` and has no network entitlement, so it cannot show a save panel that writes where you choose. `NSSavePanel` inside the Quick Look view service is not relied on. The extension writes the workbook into its own container, at `Library/Application Support/ParquetPreview/Exports/<uuid>.xlsx`, then asks **Parquet Quick Look and Index** to save it. The handoff is all three of these, so one of them can fail without losing the file:

- the URL `parquetquicklook://export?id=<uuid>` opened in the host app
- the distributed notification `com.rkrug.parquetindexer.exportReady`
- launching the host app, which on launch looks for a pending export

The host app is not sandboxed. It accepts the id only when it is a UUID, and it only copies a regular file whose path stays inside that Exports directory (the extension container, or the same folder under the real home when the preview is not sandboxed). It then shows `NSSavePanel` and copies the workbook. The app group is not used for this file: an ad-hoc signature on macOS 26 often rejects the group. The workbook is not uploaded.

A column chunk larger than 128 MiB compressed, or a row group whose metadata says it would expand past 512 MiB, is refused before it is decoded. One page that claims more than 8 MiB uncompressed is refused as well.

## Prerequisites

- **Minimum supported macOS version: 12.0 (Monterey).**

- macOS with Spotlight enabled
- Xcode Command Line Tools (`xcrun`, `clang`, `codesign`, `swiftc`)
- Rust via [rustup](https://rustup.rs) (`cargo`, stable toolchain, 1.88 or newer; the `parquet` 60 crate's MSRV)
- shell access (`zsh`)
- permission to write to `~/Library/Spotlight` and `~/Applications`

Optional checks:

```bash
xcrun --show-sdk-path
clang --version
codesign --version
```

## Build

From the project root:

```bash
./scripts/build.sh
```

This creates:

- `build/Parquet.mdimporter`
- `build/Parquet Quick Look and Index.app` (contains `ParquetQuickLook.appex`)

The build script also:

- compiles `native/parquet_preview` and links it into `ParquetQuickLook.appex` only
- copies `Info.plist` and `resources/schema.xml`
- copies the MIT license and the Apache Arrow LICENSE and NOTICE into the app's `Resources/Licenses`
- writes `build/size-report.txt` (static library size and linked extension size)
- clears extended attributes
- signs the bundle ad-hoc (required for reliable loading)

On Apple Silicon, the script also tries an Intel slice and combines them with `lipo`. If that second build fails, the app is still produced for the host architecture. GitHub Actions `macos-latest` is Apple Silicon, so the CI disk image is arm64 unless the universal link succeeds.

## Release Packaging

Automate build + DMG + GitHub release upload:

```bash
./scripts/release.sh v0.4.2
```

What it does:

- runs `./scripts/generate_icon.sh` and `./scripts/build.sh`
- creates `release/Parquet-Spotlight-0.4.2.dmg`
- creates `release/Parquet-Spotlight-0.4.2.zip`
- creates `release/Parquet-Spotlight-0.4.2.dmg.sha256`
- creates or updates the GitHub release tag and uploads those assets
- verifies release preflight before packaging:
  - current branch is `main`
  - working tree is clean
  - local `main` is fully synced with upstream

Optional flags:

- `--notes <file>`: use a custom release notes file
- `--skip-gh`: package artifacts only, do not call GitHub CLI

## GitHub Release Install (DMG)

Download the latest DMG from:

- [GitHub Releases](https://github.com/ketszeri/parquet-spotlight-quicklook/releases)

Typical asset name:

- `Parquet-Spotlight-<version>.dmg`

Unsigned app note (important):

- Releases are currently unsigned (ad-hoc signed for local loading, but not Apple Developer ID notarized).
- On first launch, macOS may block the app with a security warning.
- If blocked, right-click the app and choose `Open`, or go to:
  - `System Settings -> Privacy & Security -> Open Anyway`

## Rollback (Revert To A Previous Version)

If a new release causes problems:

1. Uninstall current version (recommended):
```bash
./scripts/uninstall.sh
```
2. Download an older DMG from:
   - [GitHub Releases](https://github.com/ketszeri/parquet-spotlight-quicklook/releases)
3. Install that older app and run `Re-Install` (or `Repair Registration`) once.

Optional verification after rollback:

```bash
mdimport -t -d2 /path/to/file.parquet
qlmanage -p /path/to/file.parquet
```

## Install

Install for current user:

```bash
./scripts/install.sh
```

This installs and registers:

- `~/Library/Spotlight/Parquet.mdimporter`
- `~/Applications/Parquet Quick Look and Index.app` (embedded modern Quick Look extension)

Use `Parquet Quick Look and Index.app` from `~/Applications` to:

- auto-install importer payload if missing (on launch)
- re-install importer payload from inside the app bundle
- repair registration and refresh caches
- uninstall importer + Quick Look app (including settings cleanup)
- change preview settings used by Quick Look
- check for updates (menu item + Updates tab), with `Skip this version` option

## Uninstall

Remove importer and preview for current user:

```bash
./scripts/uninstall.sh
```

This performs full user-level cleanup:

- app/importer/plugin removal
- Quick Look cache refresh + Finder restart
- settings/preferences/cache cleanup (best effort for container root metadata)

Dry-run mode:

```bash
./scripts/uninstall.sh --dry-run
```

## Test

1. Test-import a file and confirm plugin selection:

```bash
mdimport -t -d2 /path/to/file.parquet
```

Expected output includes:

- `with plugIn /Users/<you>/Library/Spotlight/Parquet.mdimporter`

2. Inspect indexed metadata for one file:

```bash
mdls -name kMDItemKind \
     -name com_rkrug_parquet_is_valid \
     -name com_rkrug_parquet_file_size \
     -name com_rkrug_parquet_footer_length \
     -name com_rkrug_parquet_row_count \
     -name com_rkrug_parquet_column_count \
     /path/to/file.parquet
```

3. Reindex if needed:

```bash
mdimport -r ~/Library/Spotlight/Parquet.mdimporter
mdimport /path/to/file.parquet
```

3.1. Reload Quick Look preview plugins if needed:

```bash
qlmanage -r
qlmanage -r cache
```

4. Run installation self-test:

```bash
./scripts/test_install.sh
```

Optional explicit test file:

```bash
./scripts/test_install.sh /path/to/file.parquet
```

5. Test Quick Look preview plugin:

```bash
qlmanage -p /path/to/file.parquet
```

The window should open on **Rows** with a table, and **Schema** should still show footer metadata. In the manager app, turn off `Show rows in Quick Look`, apply settings, and press Space again: the preview is schema-only. A broken file, or a file that exceeds the time or byte cap, stays on Schema with a short banner.

Sample files used by the decoder tests live in `fixtures/parquet/` (`snappy`, `zstd`, `gzip`, `lz4`, `uncompressed`, dictionary and plain, nested types, a 60-column table, 250 rows, and a malformed trailer).

6. Test dataset folder preview:

```bash
qlmanage -p /path/to/parquet-dataset-folder
```

Behavior:

- folders containing parquet files render a dataset summary preview
- non-parquet folders fall back to standard macOS folder Quick Look

Dataset scan behavior is controlled in app settings:

- `Scan all files`
- `Max files (if not all)`
- `Recursive scan folders`

7. Run script + core logic test suite:

```bash
./scripts/test_scripts.sh
```

This also runs:

```bash
./scripts/test_core.sh
./scripts/test_rows.sh
```

`test_core.sh` validates trusted update URL/tag checks, version comparisons, error mapping, and diagnostics redaction rules. `test_rows.sh` runs the Rust decoder tests against `fixtures/parquet/`.

GitHub Actions (`.github/workflows/ci.yml`) runs the same build and tests on `macos-latest`, then uploads a DMG and zip named from the app version, plus `size-report.txt`, as the `Parquet-Spotlight-macos` artifact. To install that build: download the artifact, open the disk image, drag `Parquet Quick Look and Index.app` to Applications, open it once, and use `Re-Install`. The app is ad-hoc signed, not notarized. If macOS blocks it, right-click the app and choose `Open`.

## Search

### Spotlight GUI

Use:

- `kind:Apache Parquet file`
- `name:.parquet`

### Terminal (`mdfind`)

```bash
mdfind 'kMDItemKind == "Apache Parquet file"'
mdfind 'com_rkrug_parquet_is_valid == 1'
mdfind 'com_rkrug_parquet_footer_length > 100000'
mdfind 'com_rkrug_parquet_file_size > 100000000'
mdfind 'com_rkrug_parquet_row_count > 1000000'
mdfind 'com_rkrug_parquet_column_count > 100'
mdfind 'com_rkrug_parquet_columns == "species"'
mdfind 'kMDItemKeywords == "col-species"'
```

## Troubleshooting

### `mdimport` says `with no plugIn`

Run:

```bash
mdimport -r ~/Library/Spotlight/Parquet.mdimporter
mdimport -t -d2 /path/to/file.parquet
```

If needed, reinstall:

```bash
./scripts/build.sh
./scripts/install.sh
```

### Custom fields are null in `mdls`

Force reindex the file:

```bash
mdimport /path/to/file.parquet
```

Then check again:

```bash
mdls -name com_rkrug_parquet_is_valid \
     -name com_rkrug_parquet_footer_length \
     -name com_rkrug_parquet_file_size \
     /path/to/file.parquet
```

### Spotlight results seem stale

Re-register plugin and reindex a folder:

```bash
mdimport -r ~/Library/Spotlight/Parquet.mdimporter
mdimport /path/to/folder
```

### Preview plugin not listed in `qlmanage -m plugins`

`qlmanage -m plugins` primarily lists legacy generators and may not reflect modern preview extensions.

Use this instead:

```bash
pluginkit -m -p com.apple.quicklook.preview | rg parquet
```

Spotlight indexing via `.mdimporter` is independent and unaffected.

## Exposed Properties

Standard Spotlight fields:

- `kMDItemTitle`
- `kMDItemKind` (`Apache Parquet file`)
- `kMDItemDescription`
- `kMDItemKeywords`
- `kMDItemTextContent` (metadata tokens only; no row text)

Custom Parquet fields:

- `com_rkrug_parquet_is_valid` (`CFBoolean`)
- `com_rkrug_parquet_file_size` (`CFNumber`)
- `com_rkrug_parquet_footer_length` (`CFNumber`)
- `com_rkrug_parquet_row_count` (`CFNumber`)
- `com_rkrug_parquet_column_count` (`CFNumber`)
- `com_rkrug_parquet_columns` (`CFString`, multivalued)

## Queryable `mdfind` Properties

- `com_rkrug_parquet_is_valid` (`CFBoolean`):
  - `1` if the file has a readable Parquet trailer/footer (`PAR1` + footer length), else `0`.
  - Example: `mdfind 'com_rkrug_parquet_is_valid == 1'`

- `com_rkrug_parquet_file_size` (`CFNumber`):
  - Total parquet file size in bytes (from filesystem stat at import time).
  - Example: `mdfind 'com_rkrug_parquet_file_size > 100000000'`

- `com_rkrug_parquet_footer_length` (`CFNumber`):
  - Footer metadata length in bytes (value from Parquet trailer).
  - Example: `mdfind 'com_rkrug_parquet_footer_length > 50000'`

- `com_rkrug_parquet_row_count` (`CFNumber`):
  - Best-effort extracted row count from footer metadata.
  - Example: `mdfind 'com_rkrug_parquet_row_count > 1000000'`

- `com_rkrug_parquet_column_count` (`CFNumber`):
  - Number of extracted columns stored in `com_rkrug_parquet_columns`.
  - Example: `mdfind 'com_rkrug_parquet_column_count > 100'`

- `com_rkrug_parquet_columns` (`CFString`, multivalued):
  - Best-effort extracted column names from footer metadata.
  - Example: `mdfind 'com_rkrug_parquet_columns == "Species"'`

- `kMDItemKeywords` (`CFString`, multivalued):
  - Includes generated tokens such as `col-<column_name>`, `parquet-valid`, `parquet-footer-<N>`.
  - Example: `mdfind 'kMDItemKeywords == "col-species"'`

Keyword tokens written by importer:

- `parquet`
- `parquet-valid` / `parquet-invalid`
- `parquet-footer-<N>`
- `parquet-size-<N>`
- `parquet-rows-<N>`
- `parquet-cols-<N>`
- `col-<column_name>`

## Notes

- UTI: `com.rkrug.parquet`
- Bundle ID: `com.rkrug.parquetindexer.importer`
- Plugin factory UUID: `0E198062-E6D8-4AC2-BBCE-FB860A43A116`
- Preview extension bundle ID: `com.rkrug.parquetindexer.previewhost.preview`
- Quick Look host app bundle ID: `com.rkrug.parquetindexer.previewhost`

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

Quick Look row decoding includes the Apache Arrow Rust `parquet` crate, which is Apache-2.0. Its license and notice are in [licenses/](licenses/) and are copied into the app bundle at build time. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

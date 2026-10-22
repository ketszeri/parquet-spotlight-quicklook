# Third-party notices

The Spotlight importer and the manager app are MIT licensed. See [LICENSE](LICENSE).

Quick Look row preview links the Apache Arrow Rust `parquet` crate, version 60.0.0, plus the Arrow crates it needs to format values (`arrow-array`, `arrow-schema`, `arrow-buffer`) and `serde` / `serde_json`.

- License: Apache License, Version 2.0
- Source: https://github.com/apache/arrow-rs
- Texts shipped in this repository:
  - [licenses/apache-arrow-LICENSE.txt](licenses/apache-arrow-LICENSE.txt)
  - [licenses/apache-arrow-NOTICE.txt](licenses/apache-arrow-NOTICE.txt)

`scripts/build.sh` copies those files into `Parquet Quick Look and Index.app/Contents/Resources/Licenses/`.

Apache-2.0 permits use in this MIT-licensed application. Modifications of the Arrow crates are not made in this repository. The C ABI and the byte, time, and memory caps live in `native/parquet_preview`, which is MIT licensed with the rest of the fork.

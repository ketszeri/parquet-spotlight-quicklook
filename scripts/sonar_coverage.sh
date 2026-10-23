#!/usr/bin/env bash
# Fork-only. Produces coverage reports for the SonarQube Cloud workflow.
# Normal CI does not call this script, and the release build stays optimized.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p build/coverage/profraw build/cargo-tools

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/build/native-target}"
export PATH="$ROOT/build/cargo-tools/bin:$PATH"

if [[ -f native/parquet_preview/Cargo.toml ]]; then
  if ! command -v cargo-llvm-cov >/dev/null 2>&1; then
    cargo install cargo-llvm-cov --version 0.6.19 --locked --root "$ROOT/build/cargo-tools"
  fi
  cargo llvm-cov \
    --manifest-path native/parquet_preview/Cargo.toml \
    --locked \
    --lcov \
    --output-path "$ROOT/build/coverage/rust.lcov"
  python3 - "$ROOT" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
crate = root / "native" / "parquet_preview"
report = root / "build" / "coverage" / "rust.lcov"
lines = report.read_text().splitlines(keepends=True)
out = []
for line in lines:
    if not line.startswith("SF:"):
        out.append(line)
        continue
    raw = line[3:].strip()
    path = pathlib.Path(raw)
    if path.is_absolute():
        try:
            path = path.resolve().relative_to(root)
        except ValueError:
            path = pathlib.Path(raw)
    else:
        candidate = (crate / path).resolve()
        if candidate.is_file():
            path = candidate.relative_to(root)
    out.append(f"SF:{path.as_posix()}\n")
report.write_text("".join(out))
print(f"rust lcov: {report} ({report.stat().st_size} bytes)")
PY
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "Swift coverage skipped: xcrun is not available"
  exit 0
fi

export LLVM_PROFILE_FILE="$ROOT/build/coverage/profraw/run-%p-%m.profraw"
export PARQUET_COVERAGE=1
./scripts/test_core.sh
./scripts/test_preview_host.sh

xcrun llvm-profdata merge -sparse build/coverage/profraw/*.profraw -o build/coverage/swift.profdata
objects=(
  build/tests/core_tests
  build/preview-host
  "build/ParquetPreviewTest.bundle/Contents/MacOS/ParquetPreview"
)
xcrun llvm-cov export -format=lcov -instr-profile build/coverage/swift.profdata "${objects[@]}" \
  > build/coverage/swift.lcov
xcrun llvm-cov show -instr-profile build/coverage/swift.profdata "${objects[@]}" \
  > build/coverage/swift-llvm-cov.txt

python3 - "$ROOT" <<'PY'
import pathlib, sys
from xml.sax.saxutils import escape
root = pathlib.Path(sys.argv[1]).resolve()
report = root / "build" / "coverage" / "swift.lcov"
files = {}
current = None
allowed = {".swift", ".m", ".c", ".h"}
for line in report.read_text(errors="replace").splitlines():
    if line.startswith("SF:"):
        raw = pathlib.Path(line[3:].strip())
        current = None
        if raw.is_absolute():
            try:
                raw = raw.resolve().relative_to(root)
            except ValueError:
                continue
        if raw.suffix not in allowed:
            continue
        if "Tests/" in raw.as_posix() or raw.as_posix().startswith("Tests/"):
            continue
        current = raw.as_posix()
        files.setdefault(current, {})
    elif line.startswith("DA:") and current:
        number, count = line[3:].split(",", 1)
        hits = files[current].get(int(number), 0)
        files[current][int(number)] = max(hits, int(count))

parts = ['<coverage version="1">']
for path in sorted(files):
    parts.append(f'  <file path="{escape(path)}">')
    for number in sorted(files[path]):
        covered = "true" if files[path][number] > 0 else "false"
        parts.append(f'    <lineToCover lineNumber="{number}" covered="{covered}"/>')
    parts.append("  </file>")
parts.append("</coverage>")
out = root / "build" / "coverage" / "generic.xml"
out.write_text("\n".join(parts) + "\n")
covered = sum(1 for lines in files.values() for count in lines.values() if count > 0)
total = sum(len(lines) for lines in files.values())
print(f"generic coverage: {covered}/{total} lines in {len(files)} files")
PY

{
  echo "sonar.rust.lcov.reportPaths=build/coverage/rust.lcov"
  echo "sonar.coverageReportPaths=build/coverage/generic.xml"
  echo "sonar.swift.coverage.reportPaths=build/coverage/swift-llvm-cov.txt"
} >> sonar-project.properties

test -s build/coverage/rust.lcov
test -s build/coverage/generic.xml
test -s build/coverage/swift-llvm-cov.txt
echo "coverage reports ready"

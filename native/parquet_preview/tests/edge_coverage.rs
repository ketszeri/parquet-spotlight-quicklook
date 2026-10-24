//! Paths the fixture suite does not hit: missing files, empty files, a
//! cancelled scan, and footer bounds for booleans, floats, and UUIDs.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{atomic::AtomicBool, Arc};

use arrow_array::{BooleanArray, Float32Array, Float64Array, Int64Array, RecordBatch, StringArray};
use arrow_schema::{DataType, Field, Schema};
use parquet::arrow::ArrowWriter;
use parquet_preview::{preview_path, stats_path, Limits, PreviewError, StatsLimits};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("parquet-edges-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn flag(value: bool) -> Arc<AtomicBool> {
    Arc::new(AtomicBool::new(value))
}

fn write_batch(path: &Path, schema: Arc<Schema>, batch: &RecordBatch) {
    let file = fs::File::create(path).unwrap();
    let mut writer = ArrowWriter::try_new(file, schema, None).unwrap();
    writer.write(batch).unwrap();
    writer.close().unwrap();
}

#[test]
fn preview_and_stats_reject_unreadable_paths() {
    let dir = scratch("bad");
    let missing = dir.join("missing.parquet");
    assert_eq!(preview_path(&missing, Limits::default()).unwrap_err(), PreviewError::Io);
    assert_eq!(
        stats_path(&missing, StatsLimits::default(), flag(false)).unwrap_err(),
        PreviewError::Io
    );
    assert_eq!(preview_path(&dir, Limits::default()).unwrap_err(), PreviewError::NotAFile);
    assert_eq!(
        stats_path(&dir, StatsLimits::default(), flag(false)).unwrap_err(),
        PreviewError::NotAFile
    );

    let short = dir.join("short.parquet");
    fs::write(&short, b"PAR1").unwrap();
    assert_eq!(preview_path(&short, Limits::default()).unwrap_err(), PreviewError::NotParquet);
    assert_eq!(
        stats_path(&short, StatsLimits::default(), flag(false)).unwrap_err(),
        PreviewError::NotParquet
    );

    let junk = dir.join("junk.parquet");
    fs::write(&junk, b"this is not a parquet file at all").unwrap();
    assert_eq!(preview_path(&junk, Limits::default()).unwrap_err(), PreviewError::NotParquet);
    assert_eq!(
        stats_path(&junk, StatsLimits::default(), flag(false)).unwrap_err(),
        PreviewError::NotParquet
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn empty_file_is_a_complete_preview_and_stats_scan() {
    let dir = scratch("empty");
    let path = dir.join("empty.parquet");
    let schema = Arc::new(Schema::new(vec![Field::new("id", DataType::Int64, true)]));
    let batch = RecordBatch::try_new(
        Arc::clone(&schema),
        vec![Arc::new(Int64Array::from(Vec::<Option<i64>>::new())) as _],
    )
    .unwrap();
    write_batch(&path, schema, &batch);

    let table = preview_path(&path, Limits::default()).unwrap();
    assert_eq!(table.file_rows, 0);
    assert_eq!(table.shown_rows, 0);
    assert_eq!(table.columns.len(), 1);

    let stats = stats_path(&path, StatsLimits::default(), flag(false)).unwrap();
    assert!(!stats.partial);
    assert_eq!(stats.file_rows, 0);
    assert_eq!(stats.scanned_rows, 0);
    assert_eq!(stats.columns.len(), 1);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn a_preset_cancel_fails_closed_and_the_column_cap_hides_the_rest() {
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/parquet/snappy.parquet");
    // The scan and the byte budget share one flag, so a cancel that is already
    // set fails the magic read instead of returning a partial document.
    assert_eq!(
        stats_path(&source, StatsLimits::default(), flag(true)).unwrap_err(),
        PreviewError::NotParquet
    );

    let one = StatsLimits {
        max_columns: 1,
        ..StatsLimits::default()
    };
    let limited = stats_path(&source, one, flag(false)).unwrap();
    assert_eq!(limited.total_columns, 2);
    assert_eq!(limited.shown_columns, 1);
    assert_eq!(limited.columns.len(), 1);
    assert_eq!(limited.columns[0].name, "id");

    let narrow = Limits {
        max_columns: 1,
        ..Limits::default()
    };
    let table = preview_path(&source, narrow).unwrap();
    assert_eq!(table.shown_columns, 1);
    assert_eq!(table.hidden_columns, 1);
    assert_eq!(table.columns[0].name, "id");
}

#[test]
fn footer_bounds_cover_booleans_floats_and_uuids() {
    let dir = scratch("bounds");
    let path = dir.join("bounds.parquet");
    let schema = Arc::new(Schema::new(vec![
        Field::new("flag", DataType::Boolean, true),
        Field::new("width", DataType::Float32, true),
        Field::new("score", DataType::Float64, true),
        Field::new("blank", DataType::Utf8, true),
    ]));
    let batch = RecordBatch::try_new(
        Arc::clone(&schema),
        vec![
            Arc::new(BooleanArray::from(vec![Some(false), Some(true), None])) as _,
            Arc::new(Float32Array::from(vec![Some(-2.0), Some(1.5), Some(f32::NAN)])) as _,
            Arc::new(Float64Array::from(vec![Some(0.0), None, Some(4.25)])) as _,
            Arc::new(StringArray::from(vec![Some(""), Some("  "), Some("kept")])) as _,
        ],
    )
    .unwrap();
    write_batch(&path, schema, &batch);

    let stats = stats_path(&path, StatsLimits::default(), flag(false)).unwrap();
    let column = |name: &str| stats.columns.iter().find(|column| column.name == name).unwrap();
    let flag_stats = column("flag");
    assert_eq!(flag_stats.min.as_deref(), Some("false"));
    assert_eq!(flag_stats.max.as_deref(), Some("true"));
    assert_eq!(flag_stats.nulls, 1);
    let width = column("width");
    assert_eq!(width.min.as_deref(), Some("-2"));
    assert_eq!(width.max.as_deref(), Some("1.5"));
    let score = column("score");
    assert_eq!(score.min.as_deref(), Some("0"));
    assert_eq!(score.max.as_deref(), Some("4.25"));
    let blank = column("blank");
    assert_eq!(blank.count, 1);
    assert!(blank.top.iter().any(|item| item.value == "kept"));

    let nested = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/parquet/nested_types.parquet");
    let nested_stats = stats_path(&nested, StatsLimits::default(), flag(false)).unwrap();
    let uid = nested_stats.columns.iter().find(|column| column.name == "uid").unwrap();
    assert_eq!(uid.min.as_deref(), Some("00112233-4455-6677-8899-aabbccddeeff"));
    let when = nested_stats.columns.iter().find(|column| column.name == "event_ts").unwrap();
    assert!(when.min.as_ref().unwrap().contains('T'), "{when:?}");
    assert!(when.temporal);
    let _ = fs::remove_dir_all(&dir);
}

use std::path::PathBuf;

use std::sync::{atomic::AtomicBool, Arc};

use parquet::arrow::arrow_reader::ParquetRecordBatchReaderBuilder;
use parquet::basic::Compression;
use parquet::file::reader::{FileReader, SerializedFileReader};
use parquet_preview::{preview_path, stats_path, Limits, PreviewError, StatsLimits};

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/parquet")
        .join(name)
}

fn preview(name: &str) -> parquet_preview::Preview {
    preview_path(&fixture(name), Limits::default()).unwrap_or_else(|error| {
        panic!("{name}: {error}")
    })
}

#[test]
fn codecs_round_trip_plain_values() {
    let cases = [
        ("snappy.parquet", "SNAPPY"),
        ("zstd.parquet", "ZSTD"),
        ("gzip.parquet", "GZIP"),
        ("lz4.parquet", "LZ4_RAW"),
        ("uncompressed.parquet", "UNCOMPRESSED"),
    ];
    for (name, expected_codec) in cases {
        let file = std::fs::File::open(fixture(name)).unwrap();
        let reader = SerializedFileReader::new(file).unwrap();
        let codec = reader.metadata().row_group(0).column(0).compression();
        let label = format!("{codec:?}");
        assert!(
            label.starts_with(expected_codec),
            "{name} codec was {label}"
        );
        let table = preview(name);
        assert_eq!(table.file_rows, 3);
        assert_eq!(table.shown_rows, 3);
        assert_eq!(table.cell("id", 0).unwrap().text.as_deref(), Some("0"));
        assert_eq!(table.cell("label", 0).unwrap().text.as_deref(), Some("alpha"));
        assert_eq!(table.cell("label", 1).unwrap().text.as_deref(), Some("beta"));
        assert!(table.cell("label", 2).unwrap().text.is_none());
    }
}

#[test]
fn dictionary_and_plain_encodings() {
    let file = std::fs::File::open(fixture("dictionary_plain.parquet")).unwrap();
    let reader = SerializedFileReader::new(file).unwrap();
    let group = reader.metadata().row_group(0);
    let code_encodings: Vec<String> = group
        .column(0)
        .encodings()
        .map(|encoding| format!("{encoding:?}"))
        .collect();
    let raw_encodings: Vec<String> = group
        .column(1)
        .encodings()
        .map(|encoding| format!("{encoding:?}"))
        .collect();
    assert!(
        code_encodings.iter().any(|encoding| encoding.contains("DICTIONARY")),
        "code encodings: {code_encodings:?}"
    );
    assert!(
        raw_encodings.iter().all(|encoding| !encoding.contains("DICTIONARY")),
        "raw encodings: {raw_encodings:?}"
    );
    assert_eq!(group.column(0).compression(), Compression::UNCOMPRESSED);

    let table = preview("dictionary_plain.parquet");
    assert_eq!(table.cell("code", 0).unwrap().text.as_deref(), Some("green"));
    assert_eq!(table.cell("code", 1).unwrap().text.as_deref(), Some("red"));
    assert_eq!(table.cell("raw", 0).unwrap().text.as_deref(), Some("plain-0"));
    assert_eq!(table.cell("raw", 31).unwrap().text.as_deref(), Some("plain-31"));
}

#[test]
fn nested_nulls_and_logical_types() {
    let table = preview("nested_types.parquet");
    assert_eq!(table.cell("id", 0).unwrap().text.as_deref(), Some("1"));
    assert_eq!(table.cell("name", 0).unwrap().text.as_deref(), Some("Ada"));
    assert!(table.cell("name", 1).unwrap().text.is_none());
    assert_eq!(
        table.cell("event_date", 0).unwrap().text.as_deref(),
        Some("2020-01-02")
    );
    assert_eq!(
        table.cell("event_date", 1).unwrap().text.as_deref(),
        Some("1970-01-01")
    );
    assert_eq!(
        table.cell("event_ts", 0).unwrap().text.as_deref(),
        Some("2020-01-02T03:04:05.006Z")
    );
    assert!(table.cell("event_ts", 1).unwrap().text.is_none());
    assert_eq!(table.cell("amount", 0).unwrap().text.as_deref(), Some("12.50"));
    assert_eq!(table.cell("amount", 1).unwrap().text.as_deref(), Some("-0.01"));
    let note = table.cell("note", 0).unwrap();
    assert!(note.truncated);
    assert!(note.text.as_deref().unwrap().ends_with('…'));
    assert!(note.text.as_deref().unwrap().chars().count() <= 80);
    assert_eq!(note.title.as_deref().unwrap().chars().count(), 200);
    assert_eq!(
        table.cell("uid", 0).unwrap().text.as_deref(),
        Some("00112233-4455-6677-8899-aabbccddeeff")
    );
    assert!(table.cell("uid", 1).unwrap().text.is_none());
    assert_eq!(
        table.cell("person", 0).unwrap().text.as_deref(),
        Some("{name: \"Ada\", age: 36}")
    );
    assert_eq!(
        table.cell("person", 1).unwrap().text.as_deref(),
        Some("{name: null, age: null}")
    );
    assert_eq!(table.cell("tags", 0).unwrap().text.as_deref(), Some("[1, null, 3]"));
    assert_eq!(table.cell("tags", 1).unwrap().text.as_deref(), Some("[]"));
    assert_eq!(
        table.cell("attrs", 0).unwrap().text.as_deref(),
        Some("{\"lang\": 2, \"rank\": null}")
    );
    assert!(table.cell("attrs", 1).unwrap().text.is_none());
    assert_eq!(
        table.columns.iter().find(|column| column.name == "uid").unwrap().type_name,
        "uuid"
    );
    assert!(table
        .columns
        .iter()
        .any(|column| column.name == "amount" && column.type_name == "decimal(10,2)"));
    assert!(table
        .columns
        .iter()
        .any(|column| column.name == "event_date" && column.type_name == "date"));
}

#[test]
fn wide_tables_hide_columns_past_the_cap() {
    let table = preview("wide.parquet");
    assert_eq!(table.total_columns, 60);
    assert_eq!(table.shown_columns, 50);
    assert_eq!(table.hidden_columns, 10);
    assert_eq!(table.columns[0].name, "c00");
    assert_eq!(table.columns[49].name, "c49");
    assert!(table.column_index("c50").is_none());
    assert_eq!(table.cell("c00", 0).unwrap().text.as_deref(), Some("0"));
    assert_eq!(table.cell("c49", 0).unwrap().text.as_deref(), Some("49"));
    assert!(table.cell("c00", 1).unwrap().text.is_none());
}

#[test]
fn row_cap_defaults_to_one_hundred() {
    let table = preview("many_rows.parquet");
    assert_eq!(table.file_rows, 250);
    assert_eq!(table.shown_rows, 100);
    assert_eq!(table.cell("n", 0).unwrap().text.as_deref(), Some("0"));
    assert_eq!(table.cell("n", 99).unwrap().text.as_deref(), Some("99"));
}

#[test]
fn malformed_file_fails_closed() {
    let error = preview_path(&fixture("malformed.parquet"), Limits::default()).unwrap_err();
    assert!(
        matches!(error, PreviewError::Decode | PreviewError::NotParquet),
        "{error}"
    );
}

#[test]
fn byte_cap_and_timeout_fail_closed() {
    let tiny = Limits {
        max_bytes: 8,
        ..Limits::default()
    };
    let error = preview_path(&fixture("snappy.parquet"), tiny).unwrap_err();
    assert_eq!(error, PreviewError::ByteLimit);

    let immediate = Limits {
        max_millis: 0,
        ..Limits::default()
    };
    assert_eq!(
        preview_path(&fixture("snappy.parquet"), immediate).unwrap_err(),
        PreviewError::Timeout
    );
}

#[test]
fn caller_cannot_raise_the_hard_caps() {
    let limits = Limits {
        max_rows: 10_000,
        max_columns: 10_000,
        max_bytes: u64::MAX,
        max_millis: 60_000,
    }
    .sanitized();
    assert_eq!(limits.max_rows, 1_000);
    assert_eq!(limits.max_columns, 50);
    assert_eq!(limits.max_bytes, 32 * 1024 * 1024);
    assert_eq!(limits.max_millis, 2_000);

    let table = preview_path(&fixture("row_cap.parquet"), limits).unwrap();
    assert_eq!(table.file_rows, 1_200);
    assert_eq!(table.shown_rows, 1_000);
    assert_eq!(table.cell("n", 999).unwrap().text.as_deref(), Some("999"));
}

#[test]
fn stats_use_footer_and_scanned_values() {
    let stats = stats_path(
        &fixture("snappy.parquet"),
        StatsLimits::default(),
        Arc::new(AtomicBool::new(false)),
    )
    .unwrap();
    assert!(!stats.partial);
    assert_eq!(stats.file_rows, 3);
    assert_eq!(stats.scanned_rows, 3);
    let id = stats.columns.iter().find(|column| column.name == "id").unwrap();
    assert_eq!(id.count, 3);
    assert_eq!(id.nulls, 0);
    assert_eq!(id.min.as_deref(), Some("0"));
    assert_eq!(id.max.as_deref(), Some("2"));
    assert_eq!(id.distinct, Some(3));
    assert!(id.distinct_exact);
    assert!(id.detected.is_none());
    let label = stats.columns.iter().find(|column| column.name == "label").unwrap();
    assert_eq!(label.nulls, 1);
    assert_eq!(label.nulls_scope, "footer");
    assert_eq!(label.count, 2);
    assert!(label.top.iter().any(|item| item.value == "alpha" && item.count == 1));

    let nested = stats_path(
        &fixture("nested_types.parquet"),
        StatsLimits::default(),
        Arc::new(AtomicBool::new(false)),
    )
    .unwrap();
    let amount = nested.columns.iter().find(|column| column.name == "amount").unwrap();
    assert_eq!(amount.min.as_deref(), Some("-0.01"));
    assert_eq!(amount.max.as_deref(), Some("12.5"));
    let event = nested.columns.iter().find(|column| column.name == "event_date").unwrap();
    assert_eq!(event.min.as_deref(), Some("1970-01-01"));
    assert_eq!(event.max.as_deref(), Some("2020-01-02"));
    assert!(event.temporal);
}

#[test]
fn stringly_typed_column_is_detected_while_scanning() {
    let dir = std::env::temp_dir().join(format!("parquet-stats-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("strings.parquet");
    let mut values = Vec::new();
    for index in 0..96 {
        values.push(Some(format!("{index}")));
    }
    values.extend([Some("nope".to_string()), Some("nope".to_string()), Some("nope".to_string()), Some("nope".to_string())]);
    let array = arrow_array::StringArray::from(values);
    let schema = std::sync::Arc::new(arrow_schema::Schema::new(vec![arrow_schema::Field::new(
        "code",
        arrow_schema::DataType::Utf8,
        true,
    )]));
    let batch = arrow_array::RecordBatch::try_new(schema.clone(), vec![std::sync::Arc::new(array)]).unwrap();
    let file = std::fs::File::create(&path).unwrap();
    let mut writer = parquet::arrow::ArrowWriter::try_new(file, schema, None).unwrap();
    writer.write(&batch).unwrap();
    writer.close().unwrap();

    let stats = stats_path(&path, StatsLimits::default(), Arc::new(AtomicBool::new(false))).unwrap();
    let column = &stats.columns[0];
    assert_eq!(column.detected.as_deref(), Some("int"));
    assert!((column.parsed_percent.unwrap() - 96.0).abs() < 0.05);
    assert_eq!(column.unparsed, 4);
    assert_eq!(column.min.as_deref(), Some("0"));
    assert_eq!(column.max.as_deref(), Some("95"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn arrow_reader_still_accepts_each_fixture() {
    for name in [
        "snappy.parquet",
        "zstd.parquet",
        "gzip.parquet",
        "lz4.parquet",
        "uncompressed.parquet",
        "dictionary_plain.parquet",
        "nested_types.parquet",
        "wide.parquet",
        "many_rows.parquet",
        "row_cap.parquet",
    ] {
        let file = std::fs::File::open(fixture(name)).unwrap();
        let reader = ParquetRecordBatchReaderBuilder::try_new(file).unwrap().build().unwrap();
        let batches: Vec<_> = reader.collect::<Result<Vec<_>, _>>().unwrap();
        assert!(!batches.is_empty(), "{name}");
    }
}

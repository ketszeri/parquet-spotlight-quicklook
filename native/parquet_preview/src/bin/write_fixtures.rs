//! Regenerate the committed Parquet fixtures under `fixtures/parquet`.
//!
//! ```text
//! cargo run --manifest-path native/parquet_preview/Cargo.toml --bin write_fixtures -- fixtures/parquet
//! ```

use std::env;
use std::fs::{self, File};
use std::path::Path;
use std::sync::Arc;

use arrow_array::builder::{FixedSizeBinaryBuilder, Int32Builder, ListBuilder, MapBuilder, StringBuilder};
use arrow_array::{
    ArrayRef, Decimal128Array, Int32Array, Int64Array, RecordBatch, StringArray, StructArray,
    TimestampMillisecondArray,
};
use arrow_schema::extension::Uuid;
use arrow_schema::{DataType, Field, Fields, Schema};
use parquet::arrow::ArrowWriter;
use parquet::basic::{Compression, GzipLevel, ZstdLevel};
use parquet::file::properties::WriterProperties;
use parquet::schema::types::ColumnPath;

fn main() {
    let dir = env::args()
        .nth(1)
        .unwrap_or_else(|| "fixtures/parquet".to_string());
    fs::create_dir_all(&dir).expect("create fixture dir");
    let dir = Path::new(&dir);
    if env::args().any(|arg| arg == "--only-inferred") {
        write_inferred(dir);
        println!("wrote inferred fixture in {}", dir.display());
        return;
    }

    write_codec(dir, "snappy.parquet", Compression::SNAPPY);
    write_codec(dir, "zstd.parquet", Compression::ZSTD(ZstdLevel::default()));
    write_codec(dir, "gzip.parquet", Compression::GZIP(GzipLevel::default()));
    write_codec(dir, "lz4.parquet", Compression::LZ4_RAW);
    write_codec(dir, "uncompressed.parquet", Compression::UNCOMPRESSED);
    write_dictionary(dir);
    write_nested(dir);
    write_wide(dir);
    write_many_rows(dir);
    write_row_cap(dir);
    write_malformed(dir);
    write_inferred(dir);
    println!("wrote fixtures in {}", dir.display());
}

fn write_inferred(dir: &Path) {
    let schema = Arc::new(Schema::new(vec![Field::new("price", DataType::Utf8, true)]));
    let mut values = Vec::new();
    for _ in 0..4 {
        values.push(Some("nope".to_string()));
    }
    values.push(None);
    for index in 0..95 {
        values.push(Some(format!("{index}")));
    }
    let batch = RecordBatch::try_new(Arc::clone(&schema), vec![Arc::new(StringArray::from(values))]).unwrap();
    let props = WriterProperties::builder()
        .set_compression(Compression::SNAPPY)
        .set_dictionary_enabled(false)
        .build();
    write_batch(dir.join("inferred.parquet"), schema, props, &batch);
}

fn write_codec(dir: &Path, name: &str, compression: Compression) {
    let schema = Arc::new(Schema::new(vec![
        Field::new("id", DataType::Int32, false),
        Field::new("label", DataType::Utf8, true),
    ]));
    let batch = RecordBatch::try_new(
        Arc::clone(&schema),
        vec![
            Arc::new(Int32Array::from(vec![0, 1, 2])),
            Arc::new(StringArray::from(vec![Some("alpha"), Some("beta"), None])),
        ],
    )
    .unwrap();
    let props = WriterProperties::builder()
        .set_compression(compression)
        .set_dictionary_enabled(false)
        .build();
    write_batch(dir.join(name), schema, props, &batch);
}

fn write_dictionary(dir: &Path) {
    let schema = Arc::new(Schema::new(vec![
        Field::new("code", DataType::Utf8, false),
        Field::new("raw", DataType::Utf8, false),
    ]));
    let mut codes = Vec::new();
    let mut raws = Vec::new();
    for index in 0..32 {
        codes.push(if index % 4 == 0 { "green" } else { "red" });
        raws.push(format!("plain-{index}"));
    }
    let batch = RecordBatch::try_new(
        Arc::clone(&schema),
        vec![
            Arc::new(StringArray::from(codes)),
            Arc::new(StringArray::from(raws)),
        ],
    )
    .unwrap();
    let props = WriterProperties::builder()
        .set_compression(Compression::UNCOMPRESSED)
        .set_dictionary_enabled(false)
        .set_column_dictionary_enabled(ColumnPath::from("code"), true)
        .build();
    write_batch(dir.join("dictionary_plain.parquet"), schema, props, &batch);
}

fn write_nested(dir: &Path) {
    let person_fields = Fields::from(vec![
        Field::new("name", DataType::Utf8, true),
        Field::new("age", DataType::Int32, true),
    ]);
    let person_type = DataType::Struct(person_fields.clone());
    let tags_type = DataType::List(Arc::new(Field::new("item", DataType::Int32, true)));
    let map_entries = Field::new(
        "entries",
        DataType::Struct(Fields::from(vec![
            Field::new("key", DataType::Utf8, false),
            Field::new("value", DataType::Int32, true),
        ])),
        false,
    );
    let map_type = DataType::Map(Arc::new(map_entries), false);
    let note: String = "N".repeat(200);
    let schema = Arc::new(Schema::new(vec![
        Field::new("id", DataType::Int64, false),
        Field::new("name", DataType::Utf8, true),
        Field::new("event_date", DataType::Date32, true),
        Field::new(
            "event_ts",
            DataType::Timestamp(arrow_schema::TimeUnit::Millisecond, Some("UTC".into())),
            true,
        ),
        Field::new("amount", DataType::Decimal128(10, 2), true),
        Field::new("note", DataType::Utf8, true),
        Field::new("uid", DataType::FixedSizeBinary(16), true).with_extension_type(Uuid),
        Field::new("person", person_type, true),
        Field::new("tags", tags_type, true),
        Field::new("attrs", map_type, true),
    ]));

    let dates = arrow_array::Date32Array::from(vec![Some(18_263), Some(0)]);
    let timestamps = TimestampMillisecondArray::from(vec![Some(1_577_934_245_006), None])
        .with_timezone("UTC");
    let amounts = Decimal128Array::from(vec![Some(1_250_i128), Some(-1_i128)])
        .with_precision_and_scale(10, 2)
        .unwrap();
    let mut uuids = FixedSizeBinaryBuilder::with_capacity(2, 16);
    uuids
        .append_value([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd,
            0xee, 0xff,
        ])
        .unwrap();
    uuids.append_null();
    let person = StructArray::new(
        person_fields,
        vec![
            Arc::new(StringArray::from(vec![Some("Ada"), None])) as ArrayRef,
            Arc::new(Int32Array::from(vec![Some(36), None])) as ArrayRef,
        ],
        None,
    );
    let mut tags = ListBuilder::new(Int32Builder::new());
    tags.values().append_value(1);
    tags.values().append_null();
    tags.values().append_value(3);
    tags.append(true);
    tags.append(true);
    let mut attrs = MapBuilder::new(None, StringBuilder::new(), Int32Builder::new());
    attrs.keys().append_value("lang");
    attrs.values().append_value(2);
    attrs.keys().append_value("rank");
    attrs.values().append_null();
    attrs.append(true).unwrap();
    attrs.append(false).unwrap();

    let batch = RecordBatch::try_new(
        Arc::clone(&schema),
        vec![
            Arc::new(Int64Array::from(vec![1, 2])),
            Arc::new(StringArray::from(vec![Some("Ada"), None])),
            Arc::new(dates),
            Arc::new(timestamps),
            Arc::new(amounts),
            Arc::new(StringArray::from(vec![Some(note.as_str()), Some("ok")])),
            Arc::new(uuids.finish()),
            Arc::new(person),
            Arc::new(tags.finish()),
            Arc::new(attrs.finish()),
        ],
    )
    .unwrap();
    let props = WriterProperties::builder()
        .set_compression(Compression::SNAPPY)
        .set_dictionary_enabled(false)
        .build();
    write_batch(dir.join("nested_types.parquet"), schema, props, &batch);
}

fn write_wide(dir: &Path) {
    let mut fields = Vec::new();
    let mut columns: Vec<ArrayRef> = Vec::new();
    for index in 0..60 {
        fields.push(Field::new(format!("c{index:02}"), DataType::Int32, true));
        columns.push(Arc::new(Int32Array::from(vec![Some(index), None])));
    }
    let schema = Arc::new(Schema::new(fields));
    let batch = RecordBatch::try_new(Arc::clone(&schema), columns).unwrap();
    let props = WriterProperties::builder()
        .set_compression(Compression::UNCOMPRESSED)
        .set_dictionary_enabled(false)
        .build();
    write_batch(dir.join("wide.parquet"), schema, props, &batch);
}

fn write_many_rows(dir: &Path) {
    let schema = Arc::new(Schema::new(vec![Field::new("n", DataType::Int32, false)]));
    let values: Vec<i32> = (0..250).collect();
    let batch = RecordBatch::try_new(
        Arc::clone(&schema),
        vec![Arc::new(Int32Array::from(values))],
    )
    .unwrap();
    let props = WriterProperties::builder()
        .set_compression(Compression::SNAPPY)
        .set_dictionary_enabled(false)
        .build();
    write_batch(dir.join("many_rows.parquet"), schema, props, &batch);
}

fn write_row_cap(dir: &Path) {
    let schema = Arc::new(Schema::new(vec![Field::new("n", DataType::Int32, false)]));
    let values: Vec<i32> = (0..1200).collect();
    let batch = RecordBatch::try_new(
        Arc::clone(&schema),
        vec![Arc::new(Int32Array::from(values))],
    )
    .unwrap();
    let props = WriterProperties::builder()
        .set_compression(Compression::SNAPPY)
        .set_dictionary_enabled(false)
        .build();
    write_batch(dir.join("row_cap.parquet"), schema, props, &batch);
}

fn write_malformed(dir: &Path) {
    let mut bytes = b"PAR1".to_vec();
    bytes.extend(std::iter::repeat(0xab).take(64));
    bytes.extend(20u32.to_le_bytes());
    bytes.extend(b"PAR1");
    fs::write(dir.join("malformed.parquet"), bytes).unwrap();
}

fn write_batch(path: impl AsRef<Path>, schema: Arc<Schema>, props: WriterProperties, batch: &RecordBatch) {
    let file = File::create(path).unwrap();
    let mut writer = ArrowWriter::try_new(file, schema, Some(props)).unwrap();
    writer.write(batch).unwrap();
    writer.close().unwrap();
}

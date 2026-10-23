//! Whole-file column statistics for the Quick Look Stats view.
//!
//! Footer min/max/null counts are read first. The scan then streams record
//! batches until the time or byte budget runs out. A partial scan is returned,
//! not an error, once at least the footer pass has succeeded.

use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use arrow_array::cast::AsArray;
use arrow_array::types::{
    ArrowDictionaryKeyType, Date32Type, Date64Type, Decimal128Type, Float32Type, Float64Type,
    Int16Type, Int32Type, Int64Type, Int8Type, TimestampMicrosecondType, TimestampMillisecondType,
    TimestampNanosecondType, TimestampSecondType, UInt16Type, UInt32Type, UInt64Type, UInt8Type,
};
use arrow_array::{Array, ArrayRef};
use arrow_schema::{DataType, Field, TimeUnit};
use parquet::file::reader::ChunkReader;
use parquet::arrow::arrow_reader::{ArrowReaderMetadata, ParquetRecordBatchReaderBuilder};
use parquet::arrow::ProjectionMask;
use arrow_buffer::ArrowNativeType;
use parquet::basic::{LogicalType, TimeUnit as ParquetTimeUnit};
use parquet::file::metadata::RowGroupMetaData;
use parquet::file::statistics::Statistics;
use serde::Serialize;

use crate::budget::Budget;
use crate::capped::CappedFile;
use crate::detect::{
    format_civil, parse_number, parse_temporal, percentile, sample_stddev, CivilTime,
    DetectedKind, ParsedNumber, StringProbe,
};
use crate::error::PreviewError;
use crate::format::{self, format_date32, format_timestamp};
use crate::preflight;

pub const STATS_HARD_MAX_COLUMNS: u32 = 256;
pub const STATS_HARD_MAX_BYTES: u64 = 256 * 1024 * 1024;
pub const STATS_HARD_MAX_MILLIS: u32 = 8_000;
const DISTINCT_EXACT_CAP: usize = 2_048;
const TOP_CAP: usize = 8;
const TOP_TRACK_CAP: usize = 2_048;
const PERCENTILE_CAP: usize = 8_192;
const TEXT_CHARS: usize = 80;
const BATCH_ROWS: usize = 8_192;
const GROUP_UNCOMPRESSED_CAP: u64 = 64 * 1024 * 1024;

#[derive(Debug, Clone, Copy)]
pub struct StatsLimits {
    pub max_columns: u32,
    pub max_bytes: u64,
    pub max_millis: u32,
}

impl Default for StatsLimits {
    fn default() -> Self {
        Self {
            max_columns: STATS_HARD_MAX_COLUMNS,
            max_bytes: STATS_HARD_MAX_BYTES,
            max_millis: STATS_HARD_MAX_MILLIS,
        }
    }
}

impl StatsLimits {
    pub fn sanitized(self) -> Self {
        Self {
            max_columns: self.max_columns.clamp(1, STATS_HARD_MAX_COLUMNS),
            max_bytes: self.max_bytes.min(STATS_HARD_MAX_BYTES).max(1),
            max_millis: self.max_millis.min(STATS_HARD_MAX_MILLIS).max(1),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct TopValue {
    pub value: String,
    pub count: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ColumnStats {
    pub name: String,
    pub storage_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detected: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parsed_percent: Option<f64>,
    pub unparsed: u64,
    pub count: u64,
    pub nulls: u64,
    pub null_percent: f64,
    /// `footer` when nulls come from Parquet statistics, otherwise `scanned`.
    pub nulls_scope: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub distinct: Option<u64>,
    pub distinct_exact: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max: Option<String>,
    pub min_scope: String,
    pub max_scope: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mean: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub median: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stddev: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub p25: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub p75: Option<String>,
    pub percentiles_exact: bool,
    pub temporal: bool,
    pub top: Vec<TopValue>,
}

#[derive(Debug, Clone, Serialize)]
pub struct FileStats {
    pub file_rows: i64,
    pub scanned_rows: u64,
    pub partial: bool,
    pub total_columns: usize,
    pub shown_columns: usize,
    pub columns: Vec<ColumnStats>,
}

impl FileStats {
    pub fn to_json(&self) -> Result<String, PreviewError> {
        let json = serde_json::to_string(self).map_err(|_| PreviewError::Decode)?;
        if json.len() > 2 * 1024 * 1024 {
            return Err(PreviewError::MemoryLimit);
        }
        Ok(json)
    }
}

struct StatsSource {
    arrow_meta: ArrowReaderMetadata,
    capped: CappedFile,
    budget: Arc<Budget>,
    file_rows: i64,
    total_columns: usize,
    shown: usize,
}

pub fn stats_path(
    path: &Path,
    limits: StatsLimits,
    cancel: Arc<AtomicBool>,
) -> Result<FileStats, PreviewError> {
    let limits = limits.sanitized();
    let source = open_stats(path, &limits, &cancel)?;
    let file_rows = source.file_rows;
    let total_columns = source.total_columns;
    let shown = source.shown;
    let mut columns = footer_columns(&source);
    let (mut scanned_rows, mut partial) = scan_stats(source, &mut columns, &cancel)?;
    if scanned_rows < file_rows.max(0) as u64 {
        partial = true;
    }
    // An empty file is complete, not partial.
    if file_rows <= 0 {
        partial = false;
        scanned_rows = 0;
    }
    Ok(FileStats {
        file_rows,
        scanned_rows,
        partial,
        total_columns,
        shown_columns: shown,
        columns: columns
            .into_iter()
            .map(|column| column.finish(file_rows, scanned_rows, partial))
            .collect(),
    })
}

fn open_stats(path: &Path, limits: &StatsLimits, cancel: &Arc<AtomicBool>) -> Result<StatsSource, PreviewError> {
    let meta = std::fs::metadata(path).map_err(|_| PreviewError::Io)?;
    if !meta.is_file() {
        return Err(PreviewError::NotAFile);
    }
    let file = File::open(path).map_err(|_| PreviewError::Io)?;
    let len = meta.len();
    let deadline = Instant::now() + Duration::from_millis(u64::from(limits.max_millis));
    let budget = Budget::new(limits.max_bytes, deadline, Arc::clone(cancel));
    let capped = CappedFile::new(file, len, Arc::clone(&budget));
    if capped.byte_len() < 12 {
        return Err(PreviewError::NotParquet);
    }
    let head = capped.get_bytes(0, 4).map_err(|_| PreviewError::NotParquet)?;
    let tail = capped
        .get_bytes(len.saturating_sub(4), 4)
        .map_err(|_| PreviewError::NotParquet)?;
    if head.as_ref() != b"PAR1" || tail.as_ref() != b"PAR1" {
        return Err(PreviewError::NotParquet);
    }
    let arrow_meta = ArrowReaderMetadata::load(&capped, Default::default()).map_err(|_| PreviewError::Decode)?;
    let metadata = Arc::clone(arrow_meta.metadata());
    let total_columns = arrow_meta.schema().fields().len();
    Ok(StatsSource {
        file_rows: metadata.file_metadata().num_rows(),
        total_columns,
        shown: total_columns.min(limits.max_columns as usize),
        arrow_meta,
        capped,
        budget,
    })
}

fn footer_columns(source: &StatsSource) -> Vec<ColumnAccum> {
    let metadata = source.arrow_meta.metadata();
    let schema = metadata.file_metadata().schema_descr();
    let fields = source.arrow_meta.schema().fields().clone();
    fields
        .iter()
        .take(source.shown)
        .enumerate()
        .map(|(index, field)| {
            let footer = footer_for_root(metadata.row_groups(), schema, index);
            ColumnAccum::new(field, footer)
        })
        .collect()
}

fn scan_stats(
    source: StatsSource,
    columns: &mut [ColumnAccum],
    cancel: &AtomicBool,
) -> Result<(u64, bool), PreviewError> {
    if source.shown == 0 || source.file_rows <= 0 {
        return Ok((0, false));
    }
    let metadata = Arc::clone(source.arrow_meta.metadata());
    let (row_groups, mut partial) = select_stats_groups(&source, &metadata, cancel)?;
    if row_groups.len() < metadata.num_row_groups() {
        partial = true;
    }
    if row_groups.is_empty() {
        return Ok((0, partial));
    }
    let (scanned_rows, scan_partial) = read_stats_batches(source, row_groups, columns, cancel)?;
    Ok((scanned_rows, partial || scan_partial))
}

fn select_stats_groups(
    source: &StatsSource,
    metadata: &parquet::file::metadata::ParquetMetaData,
    cancel: &AtomicBool,
) -> Result<(Vec<usize>, bool), PreviewError> {
    let mut row_groups = Vec::new();
    let mut partial = false;
    for group in 0..metadata.num_row_groups() {
        if source.budget.expired() || cancel.load(Ordering::Relaxed) {
            partial = true;
            break;
        }
        match preflight::preflight_one_group(
            &source.capped,
            metadata,
            group,
            source.shown,
            GROUP_UNCOMPRESSED_CAP,
            crate::limits::HARD_MAX_UNCOMPRESSED,
        ) {
            Ok(()) => row_groups.push(group),
            Err(PreviewError::PageTooLarge) => return Err(PreviewError::PageTooLarge),
            Err(_) => {
                partial = true;
                break;
            }
        }
    }
    Ok((row_groups, partial))
}

fn read_stats_batches(
    source: StatsSource,
    row_groups: Vec<usize>,
    columns: &mut [ColumnAccum],
    cancel: &AtomicBool,
) -> Result<(u64, bool), PreviewError> {
    let budget = Arc::clone(&source.budget);
    let shown = source.shown;
    let mask = ProjectionMask::roots(source.arrow_meta.parquet_schema(), 0..shown);
    let reader = ParquetRecordBatchReaderBuilder::new_with_metadata(source.capped, source.arrow_meta)
        .with_projection(mask)
        .with_row_groups(row_groups)
        .with_batch_size(BATCH_ROWS)
        .build()
        .map_err(|_| PreviewError::Decode)?;
    let mut scanned_rows = 0u64;
    let mut partial = false;
    for batch in reader {
        if budget.expired() || cancel.load(Ordering::Relaxed) {
            partial = true;
            break;
        }
        let batch = match batch {
            Ok(batch) => batch,
            Err(_) => {
                if scanned_rows == 0 {
                    return Err(budget.take_reason().unwrap_or(PreviewError::Decode));
                }
                partial = true;
                break;
            }
        };
        observe_stats_batch(columns, &batch, &mut scanned_rows);
    }
    Ok((scanned_rows, partial))
}

fn observe_stats_batch(columns: &mut [ColumnAccum], batch: &arrow_array::RecordBatch, scanned_rows: &mut u64) {
    let batch_fields = batch.schema().fields().clone();
    for row in 0..batch.num_rows() {
        for (index, column) in columns.iter_mut().enumerate() {
            if index >= batch.num_columns() {
                column.observe_missing();
                continue;
            }
            let field = batch_fields.get(index).map(|field| field.as_ref());
            column.observe(field, batch.column(index), row);
        }
        *scanned_rows += 1;
    }
}

struct FooterBits {
    nulls: Option<u64>,
    min: Option<String>,
    max: Option<String>,
}

fn footer_for_root(
    groups: &[RowGroupMetaData],
    schema: &parquet::schema::types::SchemaDescriptor,
    root: usize,
) -> FooterBits {
    let leaves: Vec<usize> = (0..schema.num_columns())
        .filter(|leaf| schema.get_column_root_idx(*leaf) == root)
        .collect();
    if leaves.len() != 1 {
        return FooterBits { nulls: None, min: None, max: None };
    }
    let leaf = leaves[0];
    let mut nulls: Option<u64> = Some(0);
    let mut min_key: Option<(OrderKey, String)> = None;
    let mut max_key: Option<(OrderKey, String)> = None;
    let mut min_complete = true;
    let mut max_complete = true;
    for group in groups {
        let column = group.column(leaf);
        let Some(stats) = column.statistics() else {
            return FooterBits { nulls: None, min: None, max: None };
        };
        match stats.null_count_opt() {
            Some(count) => {
                if let Some(total) = nulls.as_mut() {
                    *total = total.saturating_add(count);
                }
            }
            None => nulls = None,
        }
        let logical = column.column_descr().logical_type_ref();
        match stat_bound(stats, logical, true) {
            Some(pair) if min_complete => {
                if min_key.as_ref().map(|(current, _)| pair.0 < *current).unwrap_or(true) {
                    min_key = Some(pair);
                }
            }
            _ => {
                min_complete = false;
                min_key = None;
            }
        }
        match stat_bound(stats, logical, false) {
            Some(pair) if max_complete => {
                if max_key.as_ref().map(|(current, _)| pair.0 > *current).unwrap_or(true) {
                    max_key = Some(pair);
                }
            }
            _ => {
                max_complete = false;
                max_key = None;
            }
        }
    }
    FooterBits {
        nulls,
        min: min_key.map(|(_, text)| text),
        max: max_key.map(|(_, text)| text),
    }
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
enum OrderKey {
    Int(i128),
    Float(u64),
    Text(String),
}

fn float_key(value: f64) -> OrderKey {
    let mut bits = value.to_bits();
    if bits & (1 << 63) != 0 {
        bits = !bits;
    } else {
        bits ^= 1 << 63;
    }
    OrderKey::Float(bits)
}

fn stat_bound(stats: &Statistics, logical: Option<&LogicalType>, want_min: bool) -> Option<(OrderKey, String)> {
    if !stats.min_is_exact() || !stats.max_is_exact() {
        return None;
    }
    match stats {
        Statistics::Boolean(value) => {
            let bit = *end_ref(want_min, value.min_opt(), value.max_opt())?;
            Some(boolean_text(bit))
        }
        Statistics::Int32(value) => {
            let raw = *end_ref(want_min, value.min_opt(), value.max_opt())?;
            Some(format_int_logical(i128::from(raw), logical, true))
        }
        Statistics::Int64(value) => {
            let raw = *end_ref(want_min, value.min_opt(), value.max_opt())?;
            Some(format_int_logical(i128::from(raw), logical, false))
        }
        Statistics::Float(value) => {
            let raw = *end_ref(want_min, value.min_opt(), value.max_opt())?;
            finite_float(f64::from(raw))
        }
        Statistics::Double(value) => {
            let raw = *end_ref(want_min, value.min_opt(), value.max_opt())?;
            finite_float(raw)
        }
        Statistics::ByteArray(value) => text_stat(end_ref(want_min, value.min_opt(), value.max_opt())?.data()),
        Statistics::FixedLenByteArray(value) => fixed_stat(end_ref(want_min, value.min_opt(), value.max_opt())?.data(), logical),
        Statistics::Int96(_) => None,
    }
}

fn end_ref<'a, T>(want_min: bool, min: Option<&'a T>, max: Option<&'a T>) -> Option<&'a T> {
    if want_min { min } else { max }
}

fn boolean_text(bit: bool) -> (OrderKey, String) {
    let text = if bit { "true" } else { "false" };
    (OrderKey::Int(i128::from(bit)), text.to_string())
}

fn text_stat(bytes: &[u8]) -> Option<(OrderKey, String)> {
    let text = String::from_utf8_lossy(bytes).trim().to_string();
    if text.is_empty() {
        None
    } else {
        Some((OrderKey::Text(text.clone()), clip_text(&text)))
    }
}

fn fixed_stat(bytes: &[u8], logical: Option<&LogicalType>) -> Option<(OrderKey, String)> {
    if matches!(logical, Some(LogicalType::Uuid)) && bytes.len() == 16 {
        let text = format_uuid_bytes(bytes);
        return Some((OrderKey::Text(text.clone()), text));
    }
    text_stat(bytes)
}

fn format_int_logical(raw: i128, logical: Option<&LogicalType>, from_i32: bool) -> (OrderKey, String) {
    match logical {
        Some(LogicalType::Date) if from_i32 => {
            let text = format_date32(raw as i32);
            (OrderKey::Int(raw), text)
        }
        Some(LogicalType::Timestamp(kind)) => {
            let text = format_parquet_timestamp(raw as i64, &kind.unit);
            (OrderKey::Int(raw), text)
        }
        Some(LogicalType::Decimal(decimal)) => {
            let text = format_unscaled(raw, decimal.scale);
            (OrderKey::Int(raw), text)
        }
        Some(LogicalType::Integer(int)) if !int.is_signed && from_i32 => {
            let unsigned = raw as u32 as i128;
            (OrderKey::Int(unsigned), unsigned.to_string())
        }
        Some(LogicalType::Integer(int)) if !int.is_signed && !from_i32 => {
            let unsigned = raw as u64 as i128;
            (OrderKey::Int(unsigned), unsigned.to_string())
        }
        _ => (OrderKey::Int(raw), raw.to_string()),
    }
}

fn format_parquet_timestamp(ticks: i64, unit: &ParquetTimeUnit) -> String {
    let arrow_unit = match unit {
        ParquetTimeUnit::MILLIS => TimeUnit::Millisecond,
        ParquetTimeUnit::MICROS => TimeUnit::Microsecond,
        ParquetTimeUnit::NANOS => TimeUnit::Nanosecond,
    };
    format_timestamp(ticks, arrow_unit)
}

fn finite_float(value: f64) -> Option<(OrderKey, String)> {
    if !value.is_finite() {
        return None;
    }
    Some((float_key(value), format_number(value)))
}

fn format_unscaled(unscaled: i128, scale: i32) -> String {
    if scale <= 0 {
        return unscaled.to_string();
    }
    let negative = unscaled < 0;
    let digits = unscaled.unsigned_abs().to_string();
    let scale = scale as usize;
    let body = if digits.len() > scale {
        let split = digits.len() - scale;
        format!("{}.{}", &digits[..split], &digits[split..])
    } else {
        format!("0.{}{}", "0".repeat(scale - digits.len()), digits)
    };
    let body = body.trim_end_matches('0').trim_end_matches('.').to_string();
    let body = if body.is_empty() { "0".to_string() } else { body };
    if negative && body != "0" {
        format!("-{body}")
    } else {
        body
    }
}

fn format_uuid_bytes(bytes: &[u8]) -> String {
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

struct ColumnAccum {
    name: String,
    storage_type: String,
    kind: ValueKind,
    nulls: u64,
    values: u64,
    unparsed: u64,
    footer: FooterBits,
    numbers: NumericAccum,
    probe: StringProbe,
    temporal_numbers: NumericAccum,
    temporal_is_timestamp: bool,
    distinct: HashSet<String>,
    distinct_overflow: bool,
    top: HashMap<String, u64>,
    top_overflow: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ValueKind {
    Number,
    TemporalDate,
    TemporalTimestamp,
    Text,
    Bool,
    Other,
}

impl ColumnAccum {
    fn new(field: &Field, footer: FooterBits) -> Self {
        let storage_type = format::type_name(field);
        let kind = match field.data_type() {
            DataType::Boolean => ValueKind::Bool,
            DataType::Int8
            | DataType::Int16
            | DataType::Int32
            | DataType::Int64
            | DataType::UInt8
            | DataType::UInt16
            | DataType::UInt32
            | DataType::UInt64
            | DataType::Float32
            | DataType::Float64
            | DataType::Decimal128(_, _)
            | DataType::Decimal256(_, _) => ValueKind::Number,
            DataType::Date32 | DataType::Date64 => ValueKind::TemporalDate,
            DataType::Timestamp(_, _) => ValueKind::TemporalTimestamp,
            DataType::Utf8 | DataType::LargeUtf8 | DataType::Dictionary(_, _) | DataType::Binary | DataType::LargeBinary => {
                ValueKind::Text
            }
            _ => ValueKind::Other,
        };
        Self {
            name: field.name().to_string(),
            storage_type,
            kind,
            nulls: 0,
            values: 0,
            unparsed: 0,
            footer,
            numbers: NumericAccum::default(),
            probe: StringProbe::default(),
            temporal_numbers: NumericAccum::default(),
            temporal_is_timestamp: kind == ValueKind::TemporalTimestamp,
            distinct: HashSet::new(),
            distinct_overflow: false,
            top: HashMap::new(),
            top_overflow: false,
        }
    }

    fn observe_missing(&mut self) {
        self.nulls += 1;
    }

    fn observe(&mut self, field: Option<&Field>, array: &ArrayRef, row: usize) {
        if array.is_null(row) || array.len() <= row {
            self.nulls += 1;
            return;
        }
        if let Some(text) = text_value(array.as_ref(), row) {
            self.observe_text(&text);
            return;
        }
        if let Some(number) = number_value(array.as_ref(), row) {
            self.values += 1;
            self.note_distinct(&number.text);
            self.note_top(&number.text);
            if number.finite {
                self.numbers.add(number.value, &number.text);
            } else {
                self.unparsed += 1;
            }
            return;
        }
        if let Some(instant) = temporal_value(array.as_ref(), row) {
            self.values += 1;
            self.temporal_is_timestamp = instant.has_time;
            self.note_distinct(&instant.text);
            self.note_top(&instant.text);
            self.temporal_numbers.add(instant.epoch, &instant.text);
            return;
        }
        if let Some(field) = field {
            let cell = format::format_cell(field, array, row);
            if let Some(text) = cell.text {
                self.observe_text(&text);
                return;
            }
        }
        self.nulls += 1;
    }

    fn observe_text(&mut self, raw: &str) {
        let text = clip_text(raw.trim());
        if text.is_empty() {
            self.nulls += 1;
            return;
        }
        self.values += 1;
        self.probe.observe(&text);
        self.note_distinct(&text);
        self.note_top(&text);
        if let Some(parsed) = parse_number(&text) {
            let (value, rendered) = match parsed {
                ParsedNumber::Integer(value) => (value as f64, value.to_string()),
                ParsedNumber::Decimal(value) => (value, format_number(value)),
            };
            if value.is_finite() {
                self.numbers.add(value, &rendered);
            }
        } else if self.kind == ValueKind::Text {
            self.unparsed += 1;
        }
        if let Some(time) = parse_temporal(&text) {
            let epoch = civil_epoch(time);
            self.temporal_numbers.add(epoch, &format_civil(time));
            if time.has_time {
                self.temporal_is_timestamp = true;
            }
        }
    }

    fn note_distinct(&mut self, text: &str) {
        if self.distinct_overflow {
            return;
        }
        if self.distinct.len() >= DISTINCT_EXACT_CAP && !self.distinct.contains(text) {
            self.distinct_overflow = true;
            return;
        }
        self.distinct.insert(text.to_string());
    }

    fn note_top(&mut self, text: &str) {
        if let Some(count) = self.top.get_mut(text) {
            *count = count.saturating_add(1);
            return;
        }
        if self.top.len() >= TOP_TRACK_CAP {
            self.top_overflow = true;
            return;
        }
        self.top.insert(text.to_string(), 1);
    }

    fn finish(self, file_rows: i64, scanned_rows: u64, _partial: bool) -> ColumnStats {
        let detection = if self.kind == ValueKind::Text {
            self.probe.detection()
        } else {
            None
        };
        let use_temporal = match detection.as_ref().map(|item| item.kind) {
            Some(DetectedKind::Date) | Some(DetectedKind::Timestamp) => true,
            _ => matches!(self.kind, ValueKind::TemporalDate | ValueKind::TemporalTimestamp),
        };
        let use_numeric = match detection.as_ref().map(|item| item.kind) {
            Some(DetectedKind::Integer) | Some(DetectedKind::Decimal) | Some(DetectedKind::Boolean) => true,
            _ => matches!(self.kind, ValueKind::Number | ValueKind::Bool) && detection.is_none(),
        };
        let numeric = if use_temporal {
            self.temporal_numbers.summary(true, self.temporal_is_timestamp || detection.as_ref().map(|item| item.kind) == Some(DetectedKind::Timestamp))
        } else if use_numeric {
            self.numbers.summary(false, false)
        } else {
            NumericSummary::default()
        };
        let (nulls, nulls_scope) = if let Some(footer_nulls) = self.footer.nulls {
            (footer_nulls, "footer")
        } else {
            (self.nulls, "scanned")
        };
        let denom = if nulls_scope == "footer" {
            file_rows.max(0) as f64
        } else {
            scanned_rows as f64
        };
        let null_percent = if denom > 0.0 {
            (nulls as f64) * 100.0 / denom
        } else {
            0.0
        };
        // Footer min/max describe the stored bytes. A string column that we
        // retype uses the parsed values instead, which are not the same order.
        let retyped = detection.is_some();
        let (min, min_scope) = if retyped {
            (numeric.min.clone(), "scanned".to_string())
        } else if let Some(footer) = self.footer.min.clone() {
            (Some(footer), "footer".to_string())
        } else {
            (numeric.min.clone(), "scanned".to_string())
        };
        let (max, max_scope) = if retyped {
            (numeric.max.clone(), "scanned".to_string())
        } else if let Some(footer) = self.footer.max.clone() {
            (Some(footer), "footer".to_string())
        } else {
            (numeric.max.clone(), "scanned".to_string())
        };
        // When the scan covered every row, prefer the scanned min/max if we have them
        // and the footer is missing. Footer wins whenever it exists: it describes the file.
        let _approximate_top = self.top_overflow;
        let show_top = matches!(self.kind, ValueKind::Text | ValueKind::Other);
        let top = if show_top {
            top_list(&self.top)
        } else {
            Vec::new()
        };
        ColumnStats {
            name: self.name,
            storage_type: self.storage_type,
            detected: detection.as_ref().map(|item| item.kind.label().to_string()),
            parsed_percent: detection.as_ref().map(|item| round1(item.parsed_percent)),
            unparsed: detection.as_ref().map(|item| item.unparsed).unwrap_or(self.unparsed),
            count: self.values,
            nulls,
            null_percent: round1(null_percent),
            nulls_scope: nulls_scope.to_string(),
            distinct: if self.values == 0 && self.distinct.is_empty() {
                Some(0)
            } else if self.distinct_overflow {
                Some(self.distinct.len() as u64)
            } else {
                Some(self.distinct.len() as u64)
            },
            distinct_exact: !self.distinct_overflow,
            min,
            max,
            min_scope: min_scope.to_string(),
            max_scope,
            mean: numeric.mean,
            median: numeric.median,
            stddev: numeric.stddev,
            p25: numeric.p25,
            p75: numeric.p75,
            percentiles_exact: numeric.percentiles_exact,
            temporal: use_temporal,
            top,
        }
    }
}

fn top_list(top: &HashMap<String, u64>) -> Vec<TopValue> {
    let mut pairs: Vec<(&String, &u64)> = top.iter().collect();
    pairs.sort_by(|left, right| right.1.cmp(left.1).then_with(|| left.0.cmp(right.0)));
    pairs
        .into_iter()
        .take(TOP_CAP)
        .map(|(value, count)| TopValue {
            value: value.clone(),
            count: *count,
        })
        .collect()
}

#[derive(Default)]
struct NumericSummary {
    min: Option<String>,
    max: Option<String>,
    mean: Option<String>,
    median: Option<String>,
    stddev: Option<String>,
    p25: Option<String>,
    p75: Option<String>,
    percentiles_exact: bool,
}

#[derive(Default)]
struct NumericAccum {
    count: u64,
    mean: f64,
    m2: f64,
    min: f64,
    max: f64,
    min_text: Option<String>,
    max_text: Option<String>,
    samples: Vec<f64>,
    sample_text: Vec<String>,
    seen: u64,
    rng: u64,
    approximate: bool,
}

impl NumericAccum {
    fn add(&mut self, value: f64, text: &str) {
        if !value.is_finite() {
            return;
        }
        self.count += 1;
        let delta = value - self.mean;
        self.mean += delta / self.count as f64;
        let delta2 = value - self.mean;
        self.m2 += delta * delta2;
        if self.min_text.is_none() || value < self.min {
            self.min = value;
            self.min_text = Some(text.to_string());
        }
        if self.max_text.is_none() || value > self.max {
            self.max = value;
            self.max_text = Some(text.to_string());
        }
        self.seen += 1;
        if self.samples.len() < PERCENTILE_CAP {
            self.samples.push(value);
            self.sample_text.push(text.to_string());
            return;
        }
        self.approximate = true;
        self.rng = self.rng.wrapping_mul(6364136223846793005).wrapping_add(1);
        if self.rng == 0 {
            self.rng = 0x9E3779B97F4A7C15;
        }
        let slot = (self.rng % self.seen) as usize;
        if slot < self.samples.len() {
            self.samples[slot] = value;
            self.sample_text[slot] = text.to_string();
        }
    }

    fn summary(&self, temporal: bool, with_time: bool) -> NumericSummary {
        if self.count == 0 {
            return NumericSummary::default();
        }
        let mut samples = self.samples.clone();
        samples.sort_by(|left, right| left.total_cmp(right));
        let render = |value: f64| {
            if temporal {
                format_epoch(value, with_time)
            } else {
                format_number(value)
            }
        };
        let stddev = sample_stddev(self.count, self.m2);
        NumericSummary {
            min: self.min_text.clone(),
            max: self.max_text.clone(),
            mean: Some(if temporal { format_epoch(self.mean, with_time) } else { format_number(self.mean) }),
            median: percentile(&samples, 0.5).map(render),
            stddev: Some(if temporal {
                format!("{}s", format_number(stddev))
            } else {
                format_number(stddev)
            }),
            p25: percentile(&samples, 0.25).map(|value| {
                if temporal {
                    format_epoch(value, with_time)
                } else {
                    format_number(value)
                }
            }),
            p75: percentile(&samples, 0.75).map(|value| {
                if temporal {
                    format_epoch(value, with_time)
                } else {
                    format_number(value)
                }
            }),
            percentiles_exact: !self.approximate,
        }
    }
}

struct NumberCell {
    value: f64,
    text: String,
    finite: bool,
}

struct InstantCell {
    epoch: f64,
    text: String,
    has_time: bool,
}

fn number_value(array: &dyn Array, row: usize) -> Option<NumberCell> {
    let (value, text) = match array.data_type() {
        DataType::Int8 => {
            let value = i128::from(array.as_primitive::<Int8Type>().value(row));
            (value as f64, value.to_string())
        }
        DataType::Int16 => {
            let value = i128::from(array.as_primitive::<Int16Type>().value(row));
            (value as f64, value.to_string())
        }
        DataType::Int32 => {
            let value = i128::from(array.as_primitive::<Int32Type>().value(row));
            (value as f64, value.to_string())
        }
        DataType::Int64 => {
            let value = array.as_primitive::<Int64Type>().value(row);
            (value as f64, value.to_string())
        }
        DataType::UInt8 => {
            let value = u128::from(array.as_primitive::<UInt8Type>().value(row));
            (value as f64, value.to_string())
        }
        DataType::UInt16 => {
            let value = u128::from(array.as_primitive::<UInt16Type>().value(row));
            (value as f64, value.to_string())
        }
        DataType::UInt32 => {
            let value = u128::from(array.as_primitive::<UInt32Type>().value(row));
            (value as f64, value.to_string())
        }
        DataType::UInt64 => {
            let value = array.as_primitive::<UInt64Type>().value(row);
            (value as f64, value.to_string())
        }
        DataType::Float32 => {
            let value = f64::from(array.as_primitive::<Float32Type>().value(row));
            (value, format_number(value))
        }
        DataType::Float64 => {
            let value = array.as_primitive::<Float64Type>().value(row);
            (value, format_number(value))
        }
        DataType::Decimal128(_, scale) => {
            let raw = array.as_primitive::<Decimal128Type>().value(row);
            let text = format_unscaled(raw, i32::from(*scale));
            (text.parse::<f64>().unwrap_or(f64::NAN), text)
        }
        DataType::Boolean => {
            let value = array.as_boolean().value(row);
            let number = if value { 1.0 } else { 0.0 };
            (number, if value { "true".to_string() } else { "false".to_string() })
        }
        _ => return None,
    };
    Some(NumberCell {
        finite: value.is_finite(),
        value,
        text,
    })
}

fn temporal_value(array: &dyn Array, row: usize) -> Option<InstantCell> {
    match array.data_type() {
        DataType::Date32 => {
            let days = array.as_primitive::<Date32Type>().value(row);
            let text = format_date32(days);
            Some(InstantCell {
                epoch: f64::from(days) * 86_400.0,
                text,
                has_time: false,
            })
        }
        DataType::Date64 => {
            let millis = array.as_primitive::<Date64Type>().value(row);
            let days = millis.div_euclid(86_400_000);
            Some(InstantCell {
                epoch: millis as f64 / 1_000.0,
                text: format_date32(days as i32),
                has_time: false,
            })
        }
        DataType::Timestamp(unit, _) => {
            let ticks = match unit {
                TimeUnit::Second => array.as_primitive::<TimestampSecondType>().value(row),
                TimeUnit::Millisecond => array.as_primitive::<TimestampMillisecondType>().value(row),
                TimeUnit::Microsecond => array.as_primitive::<TimestampMicrosecondType>().value(row),
                TimeUnit::Nanosecond => array.as_primitive::<TimestampNanosecondType>().value(row),
            };
            let epoch = match unit {
                TimeUnit::Second => ticks as f64,
                TimeUnit::Millisecond => ticks as f64 / 1_000.0,
                TimeUnit::Microsecond => ticks as f64 / 1_000_000.0,
                TimeUnit::Nanosecond => ticks as f64 / 1_000_000_000.0,
            };
            Some(InstantCell {
                epoch,
                text: format_timestamp(ticks, *unit),
                has_time: true,
            })
        }
        _ => None,
    }
}

fn text_value(array: &dyn Array, row: usize) -> Option<String> {
    match array.data_type() {
        DataType::Utf8 => Some(array.as_string::<i32>().value(row).to_string()),
        DataType::LargeUtf8 => Some(array.as_string::<i64>().value(row).to_string()),
        DataType::Binary => utf8_or_hex(array.as_binary::<i32>().value(row)),
        DataType::LargeBinary => utf8_or_hex(array.as_binary::<i64>().value(row)),
        DataType::Dictionary(key, _) => match key.as_ref() {
            DataType::Int8 => dict_text::<arrow_array::types::Int8Type>(array, row),
            DataType::Int16 => dict_text::<arrow_array::types::Int16Type>(array, row),
            DataType::Int32 => dict_text::<arrow_array::types::Int32Type>(array, row),
            DataType::Int64 => dict_text::<arrow_array::types::Int64Type>(array, row),
            DataType::UInt8 => dict_text::<arrow_array::types::UInt8Type>(array, row),
            DataType::UInt16 => dict_text::<arrow_array::types::UInt16Type>(array, row),
            DataType::UInt32 => dict_text::<arrow_array::types::UInt32Type>(array, row),
            DataType::UInt64 => dict_text::<arrow_array::types::UInt64Type>(array, row),
            _ => None,
        },
        _ => None,
    }
}

fn dict_text<K: ArrowDictionaryKeyType>(array: &dyn Array, row: usize) -> Option<String> {
    let dict = array.as_dictionary::<K>();
    if dict.is_null(row) {
        return None;
    }
    let index = dict.keys().value(row).as_usize();
    text_value(dict.values().as_ref(), index)
}

fn utf8_or_hex(bytes: &[u8]) -> Option<String> {
    if let Ok(text) = std::str::from_utf8(bytes) {
        if !text.is_empty() {
            return Some(text.to_string());
        }
    }
    if bytes.is_empty() {
        return None;
    }
    Some(bytes.iter().take(16).map(|byte| format!("{byte:02x}")).collect::<Vec<_>>().join(""))
}

fn civil_epoch(time: CivilTime) -> f64 {
    let days = civil_days(time.year, time.month, time.day);
    days as f64 * 86_400.0 + f64::from(time.hour * 3600 + time.minute * 60 + time.second)
}

fn civil_days(year: i32, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year } as i64;
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64;
    let mp = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy as u64;
    (era * 146_097 + doe as i64) - 719_468
}

fn format_epoch(epoch: f64, with_time: bool) -> String {
    if !epoch.is_finite() {
        return String::new();
    }
    let seconds = epoch.round() as i64;
    let days = seconds.div_euclid(86_400);
    let date = format_date32(days as i32);
    if !with_time {
        return date;
    }
    let tod = seconds.rem_euclid(86_400) as u32;
    format!("{date}T{:02}:{:02}:{:02}Z", tod / 3600, (tod % 3600) / 60, tod % 60)
}

fn format_number(value: f64) -> String {
    if !value.is_finite() {
        return "NaN".to_string();
    }
    if value == 0.0 {
        return "0".to_string();
    }
    let abs = value.abs();
    if abs >= 1e12 || abs < 1e-4 {
        return format!("{value:.6e}");
    }
    let text = format!("{value:.6}");
    let trimmed = text.trim_end_matches('0').trim_end_matches('.');
    if trimmed.is_empty() { "0".to_string() } else { trimmed.to_string() }
}

fn clip_text(text: &str) -> String {
    let mut out = String::new();
    for (index, ch) in text.chars().enumerate() {
        if index >= TEXT_CHARS {
            out.push('…');
            break;
        }
        out.push(ch);
    }
    out
}

fn round1(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

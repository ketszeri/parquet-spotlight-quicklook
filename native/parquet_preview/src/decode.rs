use std::fs::File;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use arrow_array::cast::AsArray;
use arrow_array::types::{
    Date32Type, Date64Type, Float32Type, Float64Type, Int16Type, Int32Type, Int64Type, Int8Type,
    TimestampMicrosecondType, TimestampMillisecondType, TimestampNanosecondType, TimestampSecondType,
    UInt16Type, UInt32Type, UInt64Type, UInt8Type,
};
use arrow_array::{Array, DictionaryArray};
use arrow_buffer::ArrowNativeType;
use arrow_schema::{DataType, TimeUnit};
use parquet::arrow::arrow_reader::{ArrowReaderMetadata, ParquetRecordBatchReaderBuilder};
use parquet::arrow::ProjectionMask;
use parquet::file::reader::ChunkReader;
use serde::Serialize;

use crate::budget::Budget;
use crate::capped::CappedFile;
use crate::detect::{epoch_seconds, parse_bool, parse_number, parse_temporal, parse_uuid, ParsedNumber};
use crate::error::PreviewError;
use crate::format::{self, Cell};
use crate::limits::Limits;
use crate::preflight::{self, select_row_groups};

#[derive(Debug, Clone, Serialize)]
pub struct PreviewColumn {
    pub name: String,
    #[serde(rename = "type")]
    pub type_name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct PreviewCell {
    pub text: Option<String>,
    #[serde(skip_serializing_if = "is_false")]
    pub truncated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// Parsed numeric value, or epoch seconds for a date or timestamp.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub number: Option<f64>,
    /// Detection labels this value parses as: int, decimal, bool, date, timestamp, uuid.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub kinds: Vec<String>,
}

fn is_false(value: &bool) -> bool {
    !*value
}

impl From<Cell> for PreviewCell {
    fn from(cell: Cell) -> Self {
        Self {
            text: cell.text,
            truncated: cell.truncated,
            title: cell.title,
            number: None,
            kinds: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Preview {
    pub columns: Vec<PreviewColumn>,
    pub rows: Vec<Vec<PreviewCell>>,
    pub total_columns: usize,
    pub shown_columns: usize,
    pub hidden_columns: usize,
    pub shown_rows: usize,
    pub file_rows: i64,
}

impl Preview {
    pub fn to_json(&self) -> Result<String, PreviewError> {
        let json = serde_json::to_string(self).map_err(|_| PreviewError::Decode)?;
        if json.len() > 16 * 1024 * 1024 {
            return Err(PreviewError::MemoryLimit);
        }
        Ok(json)
    }

    pub fn column_index(&self, name: &str) -> Option<usize> {
        self.columns.iter().position(|column| column.name == name)
    }

    pub fn cell(&self, column: &str, row: usize) -> Option<&PreviewCell> {
        let index = self.column_index(column)?;
        self.rows.get(row)?.get(index)
    }
}

struct OpenedPreview {
    arrow_meta: ArrowReaderMetadata,
    capped: CappedFile,
    budget: Arc<Budget>,
    columns: Vec<PreviewColumn>,
    total_columns: usize,
    shown_columns: usize,
    file_rows: i64,
}

pub fn decode_file(
    path: &Path,
    limits: Limits,
    cancel: Arc<AtomicBool>,
) -> Result<Preview, PreviewError> {
    if cancel.load(Ordering::Relaxed) {
        return Err(PreviewError::Timeout);
    }
    let opened = open_preview(path, limits, cancel)?;
    let columns = opened.columns.clone();
    let total_columns = opened.total_columns;
    let shown_columns = opened.shown_columns;
    let file_rows = opened.file_rows;
    if shown_columns == 0 || file_rows == 0 {
        return Ok(assemble_preview(columns, Vec::new(), total_columns, shown_columns, file_rows));
    }
    let metadata = Arc::clone(opened.arrow_meta.metadata());
    let row_groups = select_row_groups(&metadata, limits.max_rows);
    preflight::preflight_row_groups(&opened.capped, &metadata, &row_groups, shown_columns)
        .map_err(|error| opened.budget.take_reason().unwrap_or(error))?;
    if opened.budget.expired() {
        return Err(opened.budget.take_reason().unwrap_or(PreviewError::Timeout));
    }
    let rows = read_preview_rows(opened, limits, row_groups)?;
    Ok(assemble_preview(columns, rows, total_columns, shown_columns, file_rows))
}

fn assemble_preview(
    columns: Vec<PreviewColumn>,
    rows: Vec<Vec<PreviewCell>>,
    total_columns: usize,
    shown_columns: usize,
    file_rows: i64,
) -> Preview {
    Preview {
        shown_rows: rows.len(),
        columns,
        rows,
        total_columns,
        shown_columns,
        hidden_columns: total_columns.saturating_sub(shown_columns),
        file_rows,
    }
}

fn open_preview(path: &Path, limits: Limits, cancel: Arc<AtomicBool>) -> Result<OpenedPreview, PreviewError> {
    let meta = std::fs::metadata(path).map_err(|_| PreviewError::Io)?;
    if !meta.is_file() {
        return Err(PreviewError::NotAFile);
    }
    let file = File::open(path).map_err(|_| PreviewError::Io)?;
    let len = meta.len();
    let deadline = Instant::now() + Duration::from_millis(u64::from(limits.max_millis));
    let budget = Budget::new(limits.max_bytes, deadline, Arc::clone(&cancel));
    let capped = CappedFile::new(file, len, Arc::clone(&budget));
    if capped.byte_len() < 12 {
        return Err(PreviewError::NotParquet);
    }
    confirm_magic(&capped, &budget)?;
    let arrow_meta = ArrowReaderMetadata::load(&capped, Default::default())
        .map_err(|error| classify(&budget, error))?;
    let metadata = Arc::clone(arrow_meta.metadata());
    let file_rows = metadata.file_metadata().num_rows();
    let fields = arrow_meta.schema().fields().clone();
    let total_columns = fields.len();
    let shown_columns = total_columns.min(limits.max_columns as usize);
    let columns = fields
        .iter()
        .take(shown_columns)
        .map(|field| PreviewColumn {
            name: field.name().to_string(),
            type_name: format::type_name(field),
        })
        .collect::<Vec<_>>();
    Ok(OpenedPreview {
        arrow_meta,
        capped,
        budget,
        columns,
        total_columns,
        shown_columns,
        file_rows,
    })
}

fn read_preview_rows(
    opened: OpenedPreview,
    limits: Limits,
    row_groups: Vec<usize>,
) -> Result<Vec<Vec<PreviewCell>>, PreviewError> {
    let shown_columns = opened.shown_columns;
    let budget = Arc::clone(&opened.budget);
    let mask = ProjectionMask::roots(opened.arrow_meta.parquet_schema(), 0..shown_columns);
    let reader = ParquetRecordBatchReaderBuilder::new_with_metadata(opened.capped, opened.arrow_meta)
        .with_projection(mask)
        .with_row_groups(row_groups)
        .with_batch_size(limits.max_rows as usize)
        .with_limit(limits.max_rows as usize)
        .build()
        .map_err(|error| classify(&budget, error))?;
    let mut rows = Vec::new();
    let mut rendered_bytes = 0usize;
    for batch in reader {
        if budget.expired() {
            return Err(budget.take_reason().unwrap_or(PreviewError::Timeout));
        }
        let batch = batch.map_err(|error| classify(&budget, error))?;
        let keep_reading = append_preview_batch(
            &mut rows,
            &mut rendered_bytes,
            &batch,
            limits.max_rows,
            shown_columns,
        )?;
        if !keep_reading {
            break;
        }
    }
    Ok(rows)
}

/// `false` stops the reader because the row cap was reached. A render-size
/// stop still returns `true` when rows remain under the cap, so later batches
/// keep the budget check the previous loop performed.
fn append_preview_batch(
    rows: &mut Vec<Vec<PreviewCell>>,
    rendered_bytes: &mut usize,
    batch: &arrow_array::RecordBatch,
    max_rows: u32,
    shown_columns: usize,
) -> Result<bool, PreviewError> {
    let batch_fields = batch.schema().fields().clone();
    for row_index in 0..batch.num_rows() {
        if rows.len() >= max_rows as usize {
            return Ok(false);
        }
        match render_preview_row(batch, &batch_fields, row_index, shown_columns, *rendered_bytes) {
            RenderedRow::TooLarge { rendered_bytes: next } => {
                *rendered_bytes = next;
                if rows.is_empty() {
                    return Err(PreviewError::MemoryLimit);
                }
                break;
            }
            RenderedRow::Cells { cells, rendered_bytes: next } => {
                *rendered_bytes = next;
                rows.push(cells);
            }
        }
    }
    Ok(rows.len() < max_rows as usize)
}

enum RenderedRow {
    TooLarge { rendered_bytes: usize },
    Cells { cells: Vec<PreviewCell>, rendered_bytes: usize },
}

fn render_preview_row(
    batch: &arrow_array::RecordBatch,
    batch_fields: &arrow_schema::Fields,
    row_index: usize,
    shown_columns: usize,
    mut rendered_bytes: usize,
) -> RenderedRow {
    let mut cells = Vec::with_capacity(shown_columns);
    for column_index in 0..shown_columns {
        let cell = preview_cell_at(batch, batch_fields, row_index, column_index);
        rendered_bytes = rendered_bytes.saturating_add(cell.text.as_ref().map(|text| text.len()).unwrap_or(0));
        if rendered_bytes > 12 * 1024 * 1024 {
            return RenderedRow::TooLarge { rendered_bytes };
        }
        cells.push(cell);
    }
    RenderedRow::Cells { cells, rendered_bytes }
}

fn preview_cell_at(
    batch: &arrow_array::RecordBatch,
    batch_fields: &arrow_schema::Fields,
    row_index: usize,
    column_index: usize,
) -> PreviewCell {
    if column_index >= batch.num_columns() {
        return null_cell();
    }
    let array = batch.column(column_index);
    match batch_fields.get(column_index) {
        Some(field) => annotated_cell(field.as_ref(), array, row_index),
        None => null_cell(),
    }
}

fn annotated_cell(field: &arrow_schema::Field, array: &arrow_array::ArrayRef, row: usize) -> PreviewCell {
    let cell = format::format_cell(field, array, row);
    let mut preview = PreviewCell::from(cell);
    if preview.text.is_none() {
        return preview;
    }
    let fallback = preview.title.clone().or_else(|| preview.text.clone());
    let (number, kinds) = annotate_value(array.as_ref(), row, fallback.as_deref());
    preview.number = number;
    preview.kinds = kinds;
    preview
}

fn annotate_value(array: &dyn Array, row: usize, fallback: Option<&str>) -> (Option<f64>, Vec<String>) {
    annotate_value_at(array, row, fallback, 0)
}

fn annotate_value_at(array: &dyn Array, row: usize, fallback: Option<&str>, depth: u8) -> (Option<f64>, Vec<String>) {
    // Dictionary pages store the value once. Compare that value, not the
    // clipped display text, so a percentile click uses the same number the
    // stats scan parsed.
    if depth < 4 {
        if let Some((values, index)) = dictionary_slot(array, row) {
            return annotate_value_at(values, index, fallback, depth + 1);
        }
    }
    if let Some(native) = native_annotation(array, row) {
        return native;
    }
    let owned = raw_text(array, row);
    annotate_text(owned.as_deref().or(fallback))
}

fn dictionary_slot(array: &dyn Array, row: usize) -> Option<(&dyn Array, usize)> {
    if !matches!(array.data_type(), DataType::Dictionary(_, _)) || array.is_null(row) || array.len() <= row {
        return None;
    }
    macro_rules! slot {
        ($($ty:ty),*) => {
            $(
                if let Some(dict) = array.as_any().downcast_ref::<DictionaryArray<$ty>>() {
                    let index = dict.keys().value(row).as_usize();
                    return Some((dict.values().as_ref(), index));
                }
            )*
        };
    }
    slot!(Int8Type, Int16Type, Int32Type, Int64Type, UInt8Type, UInt16Type, UInt32Type, UInt64Type);
    None
}

fn native_annotation(array: &dyn Array, row: usize) -> Option<(Option<f64>, Vec<String>)> {
    if array.is_null(row) || array.len() <= row {
        return Some((None, Vec::new()));
    }
    let (number, kinds): (f64, &[&str]) = match array.data_type() {
        DataType::Int8 => (array.as_primitive::<Int8Type>().value(row) as f64, &["int", "decimal"]),
        DataType::Int16 => (array.as_primitive::<Int16Type>().value(row) as f64, &["int", "decimal"]),
        DataType::Int32 => (array.as_primitive::<Int32Type>().value(row) as f64, &["int", "decimal"]),
        DataType::Int64 => (array.as_primitive::<Int64Type>().value(row) as f64, &["int", "decimal"]),
        DataType::UInt8 => (array.as_primitive::<UInt8Type>().value(row) as f64, &["int", "decimal"]),
        DataType::UInt16 => (array.as_primitive::<UInt16Type>().value(row) as f64, &["int", "decimal"]),
        DataType::UInt32 => (array.as_primitive::<UInt32Type>().value(row) as f64, &["int", "decimal"]),
        DataType::UInt64 => (array.as_primitive::<UInt64Type>().value(row) as f64, &["int", "decimal"]),
        DataType::Float32 => (f64::from(array.as_primitive::<Float32Type>().value(row)), &["decimal"]),
        DataType::Float64 => (array.as_primitive::<Float64Type>().value(row), &["decimal"]),
        DataType::Boolean => {
            let bit = array.as_boolean().value(row);
            (if bit { 1.0 } else { 0.0 }, &["bool"])
        }
        DataType::Date32 => {
            let days = array.as_primitive::<Date32Type>().value(row);
            (f64::from(days) * 86_400.0, &["date"])
        }
        DataType::Date64 => {
            let millis = array.as_primitive::<Date64Type>().value(row);
            (millis as f64 / 1_000.0, &["date"])
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
            (epoch, &["timestamp"])
        }
        _ => return None,
    };
    if !number.is_finite() {
        return Some((None, Vec::new()));
    }
    Some((Some(number), kinds.iter().map(|kind| (*kind).to_string()).collect()))
}

fn raw_text(array: &dyn Array, row: usize) -> Option<String> {
    if array.is_null(row) || array.len() <= row {
        return None;
    }
    match array.data_type() {
        DataType::Utf8 => Some(array.as_string::<i32>().value(row).to_string()),
        DataType::LargeUtf8 => Some(array.as_string::<i64>().value(row).to_string()),
        _ => None,
    }
}

fn annotate_text(text: Option<&str>) -> (Option<f64>, Vec<String>) {
    let Some(text) = text.map(str::trim).filter(|text| !text.is_empty()) else {
        return (None, Vec::new());
    };
    let mut number = None;
    let mut kinds = Vec::new();
    match parse_number(text) {
        Some(ParsedNumber::Integer(value)) => {
            kinds.push("int".to_string());
            kinds.push("decimal".to_string());
            number = Some(value as f64);
        }
        Some(ParsedNumber::Decimal(value)) if value.is_finite() => {
            kinds.push("decimal".to_string());
            number = Some(value);
        }
        _ => {}
    }
    if let Some(flag) = parse_bool(text) {
        kinds.push("bool".to_string());
        if number.is_none() {
            number = Some(if flag { 1.0 } else { 0.0 });
        }
    }
    if let Some(time) = parse_temporal(text) {
        if time.has_time {
            kinds.push("timestamp".to_string());
        } else {
            kinds.push("date".to_string());
        }
        if number.is_none() {
            number = Some(epoch_seconds(time));
        }
    }
    if parse_uuid(text) {
        kinds.push("uuid".to_string());
    }
    (number, kinds)
}

fn null_cell() -> PreviewCell {
    PreviewCell {
        text: None,
        truncated: false,
        title: None,
        number: None,
        kinds: Vec::new(),
    }
}

fn confirm_magic(file: &CappedFile, budget: &Budget) -> Result<(), PreviewError> {
    let len = file.byte_len();
    let head = file.get_bytes(0, 4).map_err(|error| classify(budget, error))?;
    let tail = file
        .get_bytes(len - 4, 4)
        .map_err(|error| classify(budget, error))?;
    if head.as_ref() == b"PAR1" && tail.as_ref() == b"PAR1" {
        Ok(())
    } else {
        Err(PreviewError::NotParquet)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cancelled_decode_stops_before_opening_the_file() {
        let cancel = Arc::new(AtomicBool::new(true));
        let error = decode_file(Path::new("missing.parquet"), Limits::default(), cancel).unwrap_err();
        assert_eq!(error, PreviewError::Timeout);
    }
}

fn classify(budget: &Budget, error: impl ToString) -> PreviewError {
    if let Some(reason) = budget.take_reason() {
        return reason;
    }
    let text = error.to_string();
    if text.contains("timed out") {
        PreviewError::Timeout
    } else if text.contains("byte limit") {
        PreviewError::ByteLimit
    } else if text.contains("not a parquet") || text.contains("magic") || text.contains("PAR1") {
        PreviewError::NotParquet
    } else {
        PreviewError::Decode
    }
}

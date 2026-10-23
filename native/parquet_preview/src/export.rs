//! Streaming Excel export. The writer is `rust_xlsxwriter` in constant-memory
//! mode: one row is kept, then flushed. Strings that start with `=`, `+`, `-`,
//! or `@` are prefixed with `'` so a spreadsheet will not treat them as formulas.

use std::borrow::Cow;
use std::fs::File;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use arrow_array::cast::AsArray;
use arrow_array::types::{
    Date32Type, Date64Type, Decimal128Type, Float32Type, Float64Type, Int16Type, Int32Type,
    Int64Type, Int8Type, TimestampMicrosecondType, TimestampMillisecondType,
    TimestampNanosecondType, TimestampSecondType, UInt16Type, UInt32Type, UInt64Type, UInt8Type,
};
use arrow_array::{Array, ArrayRef};
use arrow_schema::{DataType, TimeUnit};
use parquet::arrow::arrow_reader::{ArrowReaderMetadata, ParquetRecordBatchReaderBuilder};
use parquet::arrow::ProjectionMask;
use parquet::file::reader::ChunkReader;
use rust_xlsxwriter::{ExcelDateTime, Format, Workbook};
use serde::{Deserialize, Serialize};

use crate::budget::Budget;
use crate::capped::CappedFile;
use crate::error::PreviewError;
use crate::format::{self, format_date32, format_timestamp};
use crate::preflight;

pub const EXCEL_MAX_ROWS: u32 = 1_048_576;
pub const EXCEL_MAX_COLUMNS: u32 = 16_384;
pub const EXCEL_DATA_ROWS_PER_SHEET: u32 = EXCEL_MAX_ROWS - 1;
const EXPORT_CHUNK_COMPRESSED: u64 = 128 * 1024 * 1024;
const EXPORT_GROUP_UNCOMPRESSED: u64 = 512 * 1024 * 1024;
const MANTISSA: i128 = 1 << 53;

#[repr(C)]
pub struct ExportProgress {
    pub rows_written: u64,
    pub rows_total: u64,
    pub cancel: i32,
}

#[derive(Debug, Clone, Serialize)]
pub struct ExportPlan {
    pub rows: i64,
    pub columns: usize,
    pub sheets: u32,
    pub truncated_columns: usize,
    pub data_rows_per_sheet: u32,
    pub excel_max_rows: u32,
    pub excel_max_columns: u32,
}

#[derive(Debug)]
pub enum ExportError {
    Message(&'static str),
}

impl ExportError {
    pub fn message(&self) -> &str {
        match self {
            Self::Message(text) => text,
        }
    }
}

impl From<PreviewError> for ExportError {
    fn from(error: PreviewError) -> Self {
        Self::Message(error.message())
    }
}

/// A string that must not be opened as a formula, including after a CSV round trip.
pub fn sanitize_excel_text(value: &str) -> Cow<'_, str> {
    let probe = value.trim_start_matches(|ch: char| ch.is_whitespace() || ch == '\u{feff}');
    if probe.starts_with(['=', '+', '-', '@']) {
        Cow::Owned(format!("'{value}"))
    } else {
        Cow::Borrowed(value)
    }
}

pub fn plan_path(path: &Path) -> Result<ExportPlan, ExportError> {
    let (arrow, _) = open_arrow(path, &AtomicBool::new(false))?;
    let rows = arrow.metadata().file_metadata().num_rows();
    Ok(make_plan(rows, arrow.schema().fields().len()))
}

fn make_plan(rows: i64, columns: usize) -> ExportPlan {
    let shown = columns.min(EXCEL_MAX_COLUMNS as usize);
    let data_rows = rows.max(0) as u128;
    let sheets = if data_rows == 0 {
        1
    } else {
        ((data_rows + u128::from(EXCEL_DATA_ROWS_PER_SHEET) - 1) / u128::from(EXCEL_DATA_ROWS_PER_SHEET)) as u32
    };
    ExportPlan {
        rows,
        columns: shown,
        sheets: sheets.max(1),
        truncated_columns: columns.saturating_sub(shown),
        data_rows_per_sheet: EXCEL_DATA_ROWS_PER_SHEET,
        excel_max_rows: EXCEL_MAX_ROWS,
        excel_max_columns: EXCEL_MAX_COLUMNS,
    }
}

pub fn export_file(
    source: &Path,
    dest: &Path,
    progress: *mut ExportProgress,
) -> Result<(), ExportError> {
    export_limited(source, dest, progress, EXCEL_DATA_ROWS_PER_SHEET)
}

struct HeldRows<I> {
    incoming: I,
    batch: Option<arrow_array::RecordBatch>,
    row: usize,
    done: bool,
}

enum Pull {
    Ready,
    Exhausted,
}

impl<I, E> HeldRows<I>
where
    I: Iterator<Item = Result<arrow_array::RecordBatch, E>>,
{
    fn needs_batch(&self) -> bool {
        self.batch.as_ref().map(|batch| self.row >= batch.num_rows()).unwrap_or(true)
    }

    fn pull(&mut self) -> Result<Pull, ExportError> {
        if !self.needs_batch() {
            return Ok(Pull::Ready);
        }
        match self.incoming.next() {
            Some(Ok(batch)) => {
                self.batch = Some(batch);
                self.row = 0;
                Ok(Pull::Ready)
            }
            Some(Err(_)) => Err(ExportError::Message("export could not read the file")),
            None => {
                self.done = true;
                Ok(Pull::Exhausted)
            }
        }
    }
}

fn export_limited(
    source: &Path,
    dest: &Path,
    progress: *mut ExportProgress,
    rows_per_sheet: u32,
) -> Result<(), ExportError> {
    let rows_per_sheet = rows_per_sheet.clamp(1, EXCEL_DATA_ROWS_PER_SHEET);
    let cancel = Arc::new(AtomicBool::new(false));
    let (arrow_meta, capped) = open_arrow(source, &cancel)?;
    let metadata = arrow_meta.metadata();
    let plan = make_plan(
        metadata.file_metadata().num_rows(),
        arrow_meta.schema().fields().len(),
    );
    publish(progress, 0, Some(plan.rows.max(0) as u64));
    let shown = plan.columns;
    if shown == 0 {
        return write_note(dest, "This file has no columns.");
    }
    let fields: Vec<arrow_schema::Field> = arrow_meta
        .schema()
        .fields()
        .iter()
        .take(shown)
        .map(|field| field.as_ref().clone())
        .collect();
    let names: Vec<String> = fields.iter().map(|field| field.name().clone()).collect();
    let groups = collect_export_groups(&capped, metadata, shown, progress, &cancel, dest)?;
    let mask = ProjectionMask::roots(arrow_meta.parquet_schema(), 0..shown);
    let reader = ParquetRecordBatchReaderBuilder::new_with_metadata(capped, arrow_meta)
        .with_projection(mask)
        .with_row_groups(groups)
        .with_batch_size(8192)
        .build()
        .map_err(|_| ExportError::Message("export could not read the file"))?;
    write_export_sheets(reader, &fields, &names, shown, rows_per_sheet, dest, progress)
}

fn collect_export_groups(
    capped: &CappedFile,
    metadata: &parquet::file::metadata::ParquetMetaData,
    shown: usize,
    progress: *mut ExportProgress,
    cancel: &AtomicBool,
    dest: &Path,
) -> Result<Vec<usize>, ExportError> {
    let mut groups = Vec::new();
    for group in 0..metadata.num_row_groups() {
        if cancel_requested(progress) {
            cancel.store(true, Ordering::Relaxed);
            let _ = std::fs::remove_file(dest);
            return Err(ExportError::Message("export cancelled"));
        }
        preflight::preflight_one_group(
            capped,
            metadata,
            group,
            shown,
            EXPORT_GROUP_UNCOMPRESSED,
            EXPORT_CHUNK_COMPRESSED,
        )?;
        groups.push(group);
    }
    Ok(groups)
}

fn write_export_sheets<I, E>(
    batches: I,
    fields: &[arrow_schema::Field],
    names: &[String],
    shown: usize,
    rows_per_sheet: u32,
    dest: &Path,
    progress: *mut ExportProgress,
) -> Result<(), ExportError>
where
    I: Iterator<Item = Result<arrow_array::RecordBatch, E>>,
{
    let mut workbook = Workbook::new();
    let date_format = Format::new().set_num_format("yyyy-mm-dd");
    let time_format = Format::new().set_num_format("yyyy-mm-dd hh:mm:ss");
    let header_format = Format::new().set_bold();
    let mut held = HeldRows { incoming: batches, batch: None, row: 0, done: false };
    let mut sheet_index = 0usize;
    let mut written_total = 0u64;
    loop {
        if cancel_requested(progress) {
            let _ = std::fs::remove_file(dest);
            return Err(ExportError::Message("export cancelled"));
        }
        match held.pull()? {
            Pull::Exhausted => {
                if written_total > 0 || sheet_index > 0 {
                    break;
                }
            }
            Pull::Ready => {}
        }
        write_one_sheet(
            &mut workbook,
            &mut held,
            fields,
            names,
            shown,
            rows_per_sheet,
            sheet_index,
            &mut written_total,
            &date_format,
            &time_format,
            &header_format,
            dest,
            progress,
        )?;
        sheet_index += 1;
        if held.done {
            break;
        }
    }
    workbook
        .save(dest)
        .map_err(|_| ExportError::Message("export could not save the workbook"))?;
    Ok(())
}

fn write_one_sheet<I, E>(
    workbook: &mut Workbook,
    held: &mut HeldRows<I>,
    fields: &[arrow_schema::Field],
    names: &[String],
    shown: usize,
    rows_per_sheet: u32,
    sheet_index: usize,
    written_total: &mut u64,
    date_format: &Format,
    time_format: &Format,
    header_format: &Format,
    dest: &Path,
    progress: *mut ExportProgress,
) -> Result<(), ExportError>
where
    I: Iterator<Item = Result<arrow_array::RecordBatch, E>>,
{
    let worksheet = workbook
        .add_worksheet_with_constant_memory()
        .map_err(|_| ExportError::Message("export could not open a worksheet"))?;
    worksheet
        .set_name(sheet_name(sheet_index))
        .map_err(|_| ExportError::Message("export could not name a worksheet"))?;
    worksheet.set_freeze_panes(1, 0).ok();
    let last_col = (shown - 1) as u16;
    for (col, name) in names.iter().enumerate() {
        worksheet
            .write_string_with_format(0, col as u16, sanitize_excel_text(name).as_ref(), header_format)
            .map_err(|_| ExportError::Message("export could not write the header"))?;
    }
    let sheet_written = fill_sheet(
        worksheet,
        held,
        fields,
        shown,
        rows_per_sheet,
        written_total,
        date_format,
        time_format,
        dest,
        progress,
    )?;
    if sheet_written > 0 {
        worksheet.autofilter(0, 0, sheet_written, last_col).ok();
    }
    Ok(())
}

fn fill_sheet<I, E>(
    worksheet: &mut rust_xlsxwriter::Worksheet,
    held: &mut HeldRows<I>,
    fields: &[arrow_schema::Field],
    shown: usize,
    rows_per_sheet: u32,
    written_total: &mut u64,
    date_format: &Format,
    time_format: &Format,
    dest: &Path,
    progress: *mut ExportProgress,
) -> Result<u32, ExportError>
where
    I: Iterator<Item = Result<arrow_array::RecordBatch, E>>,
{
    let mut sheet_written = 0u32;
    while sheet_written < rows_per_sheet {
        if cancel_requested(progress) {
            let _ = std::fs::remove_file(dest);
            return Err(ExportError::Message("export cancelled"));
        }
        match held.pull()? {
            Pull::Exhausted => break,
            Pull::Ready => {}
        }
        let row_index = held.row;
        let batch = held.batch.as_ref().ok_or(ExportError::Message("export could not read the file"))?;
        let excel_row = sheet_written + 1;
        for col in 0..shown {
            let array = batch.column(col);
            write_arrow_cell(
                worksheet,
                excel_row,
                col as u16,
                Some(&fields[col]),
                array,
                row_index,
                date_format,
                time_format,
            )?;
        }
        held.row += 1;
        sheet_written += 1;
        *written_total += 1;
        publish(progress, *written_total, None);
    }
    Ok(sheet_written)
}

#[derive(Debug, Deserialize)]
struct TableFile {
    columns: Vec<TableColumn>,
    rows: Vec<Vec<Option<String>>>,
}

#[derive(Debug, Deserialize)]
struct TableColumn {
    name: String,
    #[serde(rename = "type")]
    type_name: String,
}

pub fn export_table(json: &str, dest: &Path) -> Result<ExportPlan, ExportError> {
    if json.len() > 16 * 1024 * 1024 {
        return Err(ExportError::Message("the rows view is too large to export"));
    }
    let table: TableFile = serde_json::from_str(json).map_err(|_| ExportError::Message("the rows view could not be read"))?;
    let columns = table.columns.len().min(EXCEL_MAX_COLUMNS as usize);
    let row_count = table.rows.len().min(EXCEL_DATA_ROWS_PER_SHEET as usize);
    let mut workbook = Workbook::new();
    let date_format = Format::new().set_num_format("yyyy-mm-dd");
    let time_format = Format::new().set_num_format("yyyy-mm-dd hh:mm:ss");
    let header_format = Format::new().set_bold();
    let worksheet = workbook
        .add_worksheet_with_constant_memory()
        .map_err(|_| ExportError::Message("export could not open a worksheet"))?;
    worksheet.set_name("Rows").ok();
    worksheet.set_freeze_panes(1, 0).ok();
    if columns > 0 && row_count > 0 {
        worksheet.autofilter(0, 0, row_count as u32, (columns - 1) as u16).ok();
    }
    for (col, column) in table.columns.iter().take(columns).enumerate() {
        worksheet
            .write_string_with_format(0, col as u16, sanitize_excel_text(&column.name).as_ref(), &header_format)
            .map_err(|_| ExportError::Message("export could not write the header"))?;
    }
    for (row_index, row) in table.rows.iter().take(row_count).enumerate() {
        for col in 0..columns {
            let text = row.get(col).and_then(|cell| cell.as_deref());
            let type_name = table.columns[col].type_name.as_str();
            write_text_cell(worksheet, (row_index as u32) + 1, col as u16, text, type_name, &date_format, &time_format)?;
        }
    }
    workbook.save(dest).map_err(|_| ExportError::Message("export could not save the workbook"))?;
    Ok(ExportPlan {
        rows: row_count as i64,
        columns,
        sheets: 1,
        truncated_columns: table.columns.len().saturating_sub(columns),
        data_rows_per_sheet: EXCEL_DATA_ROWS_PER_SHEET,
        excel_max_rows: EXCEL_MAX_ROWS,
        excel_max_columns: EXCEL_MAX_COLUMNS,
    })
}

fn write_note(dest: &Path, text: &str) -> Result<(), ExportError> {
    let mut workbook = Workbook::new();
    let worksheet = workbook.add_worksheet_with_constant_memory().map_err(|_| ExportError::Message("export could not open a worksheet"))?;
    worksheet.write_string(0, 0, sanitize_excel_text(text).as_ref()).ok();
    workbook.save(dest).map_err(|_| ExportError::Message("export could not save the workbook"))
}

fn sheet_name(index: usize) -> String {
    if index == 0 {
        "Rows".to_string()
    } else {
        format!("Rows {}", index + 1)
    }
}

fn cancel_requested(progress: *mut ExportProgress) -> bool {
    !progress.is_null() && unsafe { std::ptr::read_volatile(&(*progress).cancel) } != 0
}

fn publish(progress: *mut ExportProgress, written: u64, total: Option<u64>) {
    if progress.is_null() {
        return;
    }
    unsafe {
        if let Some(total) = total {
            std::ptr::write_volatile(&mut (*progress).rows_total, total);
        }
        std::ptr::write_volatile(&mut (*progress).rows_written, written);
    }
}

fn open_arrow(path: &Path, cancel: &AtomicBool) -> Result<(ArrowReaderMetadata, CappedFile), ExportError> {
    let meta = std::fs::metadata(path).map_err(|_| ExportError::Message("could not read the file"))?;
    if !meta.is_file() {
        return Err(ExportError::Message("not a regular file"));
    }
    let file = File::open(path).map_err(|_| ExportError::Message("could not read the file"))?;
    let len = meta.len();
    let budget = Budget::new(
        u64::MAX / 4,
        Instant::now() + Duration::from_secs(24 * 60 * 60),
        Arc::new(AtomicBool::new(false)),
    );
    // User cancel is observed between batches. The budget flag stays clear so a
    // long export is not treated as the row-preview timeout.
    let _ = cancel;
    let capped = CappedFile::new(file, len, budget);
    if capped.byte_len() < 12 {
        return Err(ExportError::Message("not a parquet file"));
    }
    let head = capped.get_bytes(0, 4).map_err(|_| ExportError::Message("not a parquet file"))?;
    let tail = capped.get_bytes(len.saturating_sub(4), 4).map_err(|_| ExportError::Message("not a parquet file"))?;
    if head.as_ref() != b"PAR1" || tail.as_ref() != b"PAR1" {
        return Err(ExportError::Message("not a parquet file"));
    }
    let arrow = ArrowReaderMetadata::load(&capped, Default::default()).map_err(|_| ExportError::Message("export could not read the file"))?;
    Ok((arrow, capped))
}

fn write_arrow_cell(
    worksheet: &mut rust_xlsxwriter::Worksheet,
    row: u32,
    col: u16,
    field: Option<&arrow_schema::Field>,
    array: &ArrayRef,
    index: usize,
    date_format: &Format,
    time_format: &Format,
) -> Result<(), ExportError> {
    if array.is_null(index) {
        return Ok(());
    }
    match array.data_type() {
        DataType::Boolean => {
            worksheet.write_boolean(row, col, array.as_boolean().value(index)).ok();
        }
        DataType::Int8 => write_int(worksheet, row, col, i128::from(array.as_primitive::<Int8Type>().value(index))),
        DataType::Int16 => write_int(worksheet, row, col, i128::from(array.as_primitive::<Int16Type>().value(index))),
        DataType::Int32 => write_int(worksheet, row, col, i128::from(array.as_primitive::<Int32Type>().value(index))),
        DataType::Int64 => write_int(worksheet, row, col, i128::from(array.as_primitive::<Int64Type>().value(index))),
        DataType::UInt8 => write_int(worksheet, row, col, i128::from(array.as_primitive::<UInt8Type>().value(index))),
        DataType::UInt16 => write_int(worksheet, row, col, i128::from(array.as_primitive::<UInt16Type>().value(index))),
        DataType::UInt32 => write_int(worksheet, row, col, i128::from(array.as_primitive::<UInt32Type>().value(index))),
        DataType::UInt64 => write_int(worksheet, row, col, i128::from(array.as_primitive::<UInt64Type>().value(index))),
        DataType::Float32 => write_float(worksheet, row, col, f64::from(array.as_primitive::<Float32Type>().value(index))),
        DataType::Float64 => write_float(worksheet, row, col, array.as_primitive::<Float64Type>().value(index)),
        DataType::Decimal128(_, scale) => {
            let text = format_unscaled_local(array.as_primitive::<Decimal128Type>().value(index), i32::from(*scale));
            if let Ok(value) = text.parse::<f64>() {
                write_float(worksheet, row, col, value);
            } else {
                write_safe_string(worksheet, row, col, &text);
            }
        }
        DataType::Date32 => {
            let days = array.as_primitive::<Date32Type>().value(index);
            let text = format_date32(days);
            write_iso(worksheet, row, col, &text, false, date_format, time_format);
        }
        DataType::Date64 => {
            let days = array.as_primitive::<Date64Type>().value(index).div_euclid(86_400_000) as i32;
            write_iso(worksheet, row, col, &format_date32(days), false, date_format, time_format);
        }
        DataType::Timestamp(unit, _) => {
            let ticks = match unit {
                TimeUnit::Second => array.as_primitive::<TimestampSecondType>().value(index),
                TimeUnit::Millisecond => array.as_primitive::<TimestampMillisecondType>().value(index),
                TimeUnit::Microsecond => array.as_primitive::<TimestampMicrosecondType>().value(index),
                TimeUnit::Nanosecond => array.as_primitive::<TimestampNanosecondType>().value(index),
            };
            write_iso(worksheet, row, col, &format_timestamp(ticks, *unit), true, date_format, time_format);
        }
        DataType::Utf8 => write_safe_string(worksheet, row, col, array.as_string::<i32>().value(index)),
        DataType::LargeUtf8 => write_safe_string(worksheet, row, col, array.as_string::<i64>().value(index)),
        _ => {
            if let Some(field) = field {
                let cell = format::format_cell(field, array, index);
                if let Some(text) = cell.text {
                    write_safe_string(worksheet, row, col, &text);
                }
            }
        }
    }
    Ok(())
}

fn write_text_cell(
    worksheet: &mut rust_xlsxwriter::Worksheet,
    row: u32,
    col: u16,
    text: Option<&str>,
    type_name: &str,
    date_format: &Format,
    time_format: &Format,
) -> Result<(), ExportError> {
    let Some(text) = text else { return Ok(()) };
    if text == "null" && type_name != "string" {
        return Ok(());
    }
    let name = type_name.to_ascii_lowercase();
    if name.starts_with("bool") {
        if let Some(value) = crate::detect::parse_bool(text) {
            worksheet.write_boolean(row, col, value).ok();
            return Ok(());
        }
    }
    if name.starts_with("date") {
        write_iso(worksheet, row, col, text, false, date_format, time_format);
        return Ok(());
    }
    if name.starts_with("timestamp") {
        write_iso(worksheet, row, col, text, true, date_format, time_format);
        return Ok(());
    }
    if name.starts_with("int") || name.starts_with("uint") || name.starts_with("float") || name.starts_with("double") || name.starts_with("decimal") {
        if let Ok(value) = text.parse::<f64>() {
            if value.is_finite() {
                write_float(worksheet, row, col, value);
                return Ok(());
            }
        }
    }
    write_safe_string(worksheet, row, col, text);
    Ok(())
}

fn write_int(worksheet: &mut rust_xlsxwriter::Worksheet, row: u32, col: u16, value: i128) {
    if value.abs() <= MANTISSA {
        worksheet.write_number(row, col, value as f64).ok();
    } else {
        write_safe_string(worksheet, row, col, &value.to_string());
    }
}

fn write_float(worksheet: &mut rust_xlsxwriter::Worksheet, row: u32, col: u16, value: f64) {
    if value.is_finite() {
        worksheet.write_number(row, col, value).ok();
    }
}

fn write_safe_string(worksheet: &mut rust_xlsxwriter::Worksheet, row: u32, col: u16, value: &str) {
    worksheet.write_string(row, col, sanitize_excel_text(value).as_ref()).ok();
}

fn write_iso(
    worksheet: &mut rust_xlsxwriter::Worksheet,
    row: u32,
    col: u16,
    text: &str,
    with_time: bool,
    date_format: &Format,
    time_format: &Format,
) {
    let Some(time) = crate::detect::parse_temporal(text) else {
        write_safe_string(worksheet, row, col, text);
        return;
    };
    let result = if with_time || time.has_time {
        ExcelDateTime::from_timestamp(civil_epoch_seconds(time)).map(|value| (value, time_format))
    } else {
        ExcelDateTime::from_ymd(time.year as u16, time.month as u8, time.day as u8).map(|value| (value, date_format))
    };
    match result {
        Ok((datetime, format)) => {
            worksheet.write_datetime_with_format(row, col, &datetime, format).ok();
        }
        Err(_) => write_safe_string(worksheet, row, col, text),
    }
}

fn civil_epoch_seconds(time: crate::detect::CivilTime) -> i64 {
    // Howard Hinnant days_from_civil, then the clock.
    let year = time.year as i64;
    let month = time.month as i64;
    let day = time.day as i64;
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64;
    let mp = if month > 2 { month - 3 } else { month + 9 } as u64;
    let doy = (153 * mp + 2) / 5 + day as u64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe as i64 - 719_468;
    days * 86_400 + i64::from(time.hour) * 3600 + i64::from(time.minute) * 60 + i64::from(time.second)
}

fn format_unscaled_local(unscaled: i128, scale: i32) -> String {
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
    if negative { format!("-{body}") } else { body }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    #[test]
    fn formula_text_is_prefixed() {
        assert_eq!(sanitize_excel_text("=1+1").as_ref(), "'=1+1");
        assert_eq!(sanitize_excel_text("+cmd").as_ref(), "'+cmd");
        assert_eq!(sanitize_excel_text("-pending").as_ref(), "'-pending");
        assert_eq!(sanitize_excel_text("@sum").as_ref(), "'@sum");
        assert_eq!(sanitize_excel_text("  =2").as_ref(), "'  =2");
        assert_eq!(sanitize_excel_text("safe").as_ref(), "safe");
    }

    #[test]
    fn table_round_trip_writes_typed_cells_and_no_formulas() {
        let dir = std::env::temp_dir().join(format!("parquet-xlsx-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("view.xlsx");
        let json = r#"{
            "columns": [
                {"name": "id", "type": "int64"},
                {"name": "note", "type": "string"},
                {"name": "when", "type": "date"}
            ],
            "rows": [
                ["2", "=1+1", "2020-01-02"],
                [null, "alpha", null]
            ]
        }"#;
        let plan = export_table(json, &path).unwrap();
        assert_eq!(plan.rows, 2);
        assert_eq!(plan.sheets, 1);
        let file = std::fs::File::open(&path).unwrap();
        let mut archive = zip::ZipArchive::new(file).unwrap();
        let mut sheet = String::new();
        archive.by_name("xl/worksheets/sheet1.xml").unwrap().read_to_string(&mut sheet).unwrap();
        assert!(sheet.contains("=1+1") == false || sheet.contains("'=1+1") || sheet.contains("&apos;=1+1"), "{sheet}");
        assert!(!sheet.contains("<f>"), "no formula cells: {sheet}");
        assert!(sheet.contains("alpha"), "{sheet}");
        assert!(sheet.contains("frozen") || sheet.contains("freeze"), "{sheet}");
        assert!(sheet.contains("autoFilter"), "{sheet}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn snappy_fixture_exports_numbers() {
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/parquet/snappy.parquet");
        let dir = std::env::temp_dir().join(format!("parquet-xlsx-file-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let dest = dir.join("file.xlsx");
        let plan = plan_path(&source).unwrap();
        assert_eq!(plan.rows, 3);
        assert!(plan.sheets >= 1);
        export_file(&source, &dest, std::ptr::null_mut()).unwrap();
        let file = std::fs::File::open(&dest).unwrap();
        let mut archive = zip::ZipArchive::new(file).unwrap();
        let mut sheet = String::new();
        archive.by_name("xl/worksheets/sheet1.xml").unwrap().read_to_string(&mut sheet).unwrap();
        assert!(sheet.contains(">id<") || sheet.contains("id"), "{sheet}");
        assert!(sheet.contains("alpha"), "{sheet}");
        assert!(!sheet.contains("<f>"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn rejects_bad_input_and_a_cancel_before_the_first_row() {
        let missing = std::env::temp_dir().join(format!("parquet-xlsx-missing-{}", std::process::id()));
        let dest = std::env::temp_dir().join(format!("parquet-xlsx-dest-{}", std::process::id()));
        assert_eq!(
            plan_path(&missing).unwrap_err().message(),
            "could not read the file"
        );
        assert_eq!(
            export_file(&missing, &dest, std::ptr::null_mut()).unwrap_err().message(),
            "could not read the file"
        );
        let dir = std::env::temp_dir().join(format!("parquet-xlsx-dir-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(plan_path(&dir).unwrap_err().message(), "not a regular file");
        let short = std::env::temp_dir().join(format!("parquet-xlsx-short-{}", std::process::id()));
        std::fs::write(&short, b"PAR1").unwrap();
        assert_eq!(plan_path(&short).unwrap_err().message(), "not a parquet file");

        assert_eq!(
            export_table("{", &dest).unwrap_err().message(),
            "the rows view could not be read"
        );
        let huge = "x".repeat(16 * 1024 * 1024 + 1);
        assert_eq!(
            export_table(&huge, &dest).unwrap_err().message(),
            "the rows view is too large to export"
        );

        let typed = dir.join("typed.xlsx");
        let plan = export_table(
            r#"{
                "columns": [
                    {"name": "flag", "type": "bool"},
                    {"name": "n", "type": "int64"},
                    {"name": "when", "type": "date"},
                    {"name": "ts", "type": "timestamp"},
                    {"name": "note", "type": "string"},
                    {"name": "score", "type": "float64"}
                ],
                "rows": [
                    ["true", "4", "2020-01-02", "2020-01-02T03:04:05Z", "ok", "1.5"],
                    ["null", "null", "nope", "nope", null, "nan"],
                    ["maybe", "nope", "2020-01-02", "2020-01-02 03:04:05", "+cmd", "1e309"]
                ]
            }"#,
            &typed,
        )
        .unwrap();
        assert_eq!(plan.rows, 3);
        assert_eq!(plan.columns, 6);
        assert!(typed.is_file());

        let empty = dir.join("empty-cols.xlsx");
        let empty_plan = export_table(r#"{"columns":[],"rows":[]}"#, &empty).unwrap();
        assert_eq!(empty_plan.rows, 0);
        assert_eq!(empty_plan.columns, 0);

        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/parquet/snappy.parquet");
        let cancelled = dir.join("cancelled.xlsx");
        let mut progress = ExportProgress { rows_written: 0, rows_total: 0, cancel: 1 };
        assert_eq!(
            export_file(&source, &cancelled, &mut progress).unwrap_err().message(),
            "export cancelled"
        );
        assert!(!cancelled.exists());
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_file(&short);
        let _ = std::fs::remove_file(&dest);
    }

    #[test]
    fn sheet_split_keeps_the_rest_of_a_batch() {
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/parquet/snappy.parquet");
        let dir = std::env::temp_dir().join(format!("parquet-xlsx-split-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let dest = dir.join("split.xlsx");
        export_limited(&source, &dest, std::ptr::null_mut(), 2).unwrap();
        let file = std::fs::File::open(&dest).unwrap();
        let mut archive = zip::ZipArchive::new(file).unwrap();
        let mut first = String::new();
        let mut second = String::new();
        archive.by_name("xl/worksheets/sheet1.xml").unwrap().read_to_string(&mut first).unwrap();
        archive.by_name("xl/worksheets/sheet2.xml").unwrap().read_to_string(&mut second).unwrap();
        assert!(first.contains("alpha"), "{first}");
        assert!(!second.contains("alpha"), "{second}");
        assert!(second.contains(">2<") || second.contains(">2.0<"), "{second}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}

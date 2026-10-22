use std::fs::File;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use parquet::arrow::arrow_reader::{ArrowReaderMetadata, ParquetRecordBatchReaderBuilder};
use parquet::arrow::ProjectionMask;
use parquet::file::reader::ChunkReader;
use serde::Serialize;

use crate::budget::Budget;
use crate::capped::CappedFile;
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

pub fn decode_file(
    path: &Path,
    limits: Limits,
    cancel: Arc<AtomicBool>,
) -> Result<Preview, PreviewError> {
    if cancel.load(Ordering::Relaxed) {
        return Err(PreviewError::Timeout);
    }
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

    let arrow_meta = ArrowReaderMetadata::load(&capped, Default::default()).map_err(|error| {
        classify(&budget, error)
    })?;
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

    if shown_columns == 0 || file_rows == 0 {
        return Ok(Preview {
            columns,
            rows: Vec::new(),
            total_columns,
            shown_columns,
            hidden_columns: total_columns.saturating_sub(shown_columns),
            shown_rows: 0,
            file_rows,
        });
    }

    let row_groups = select_row_groups(&metadata, limits.max_rows);
    preflight::preflight_row_groups(&capped, &metadata, &row_groups, shown_columns)
        .map_err(|error| budget.take_reason().unwrap_or(error))?;

    if budget.expired() {
        return Err(budget.take_reason().unwrap_or(PreviewError::Timeout));
    }

    let mask = ProjectionMask::roots(arrow_meta.parquet_schema(), 0..shown_columns);
    let reader = ParquetRecordBatchReaderBuilder::new_with_metadata(capped, arrow_meta)
        .with_projection(mask)
        .with_row_groups(row_groups)
        .with_batch_size(limits.max_rows as usize)
        .with_limit(limits.max_rows as usize)
        .build()
        .map_err(|error| classify(&budget, error))?;

    let mut rows = Vec::new();
    let mut rendered_bytes: usize = 0;
    for batch in reader {
        if budget.expired() {
            return Err(budget.take_reason().unwrap_or(PreviewError::Timeout));
        }
        let batch = batch.map_err(|error| classify(&budget, error))?;
        let batch_fields = batch.schema().fields().clone();
        for row_index in 0..batch.num_rows() {
            if rows.len() >= limits.max_rows as usize {
                break;
            }
            let mut cells = Vec::with_capacity(shown_columns);
            let mut over_budget = false;
            for column_index in 0..shown_columns {
                let cell = if column_index < batch.num_columns() {
                    if let Some(field) = batch_fields.get(column_index) {
                        format::format_cell(field.as_ref(), batch.column(column_index), row_index).into()
                    } else {
                        null_cell()
                    }
                } else {
                    null_cell()
                };
                rendered_bytes = rendered_bytes.saturating_add(
                    cell.text.as_ref().map(|text| text.len()).unwrap_or(0),
                );
                if rendered_bytes > 12 * 1024 * 1024 {
                    over_budget = true;
                    break;
                }
                cells.push(cell);
            }
            if over_budget {
                if rows.is_empty() {
                    return Err(PreviewError::MemoryLimit);
                }
                break;
            }
            rows.push(cells);
        }
        if rows.len() >= limits.max_rows as usize {
            break;
        }
    }

    Ok(Preview {
        shown_rows: rows.len(),
        columns,
        rows,
        total_columns,
        shown_columns,
        hidden_columns: total_columns.saturating_sub(shown_columns),
        file_rows,
    })
}

fn null_cell() -> PreviewCell {
    PreviewCell {
        text: None,
        truncated: false,
        title: None,
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

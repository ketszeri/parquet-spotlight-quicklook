use parquet::file::metadata::{ColumnChunkMetaData, ParquetMetaData, RowGroupMetaData};
use parquet::file::reader::ChunkReader;

use crate::error::PreviewError;
use crate::limits::{HARD_MAX_PAGE_UNCOMPRESSED, HARD_MAX_UNCOMPRESSED};

const MAX_PAGES: usize = 10_000;
const MAX_HEADER_BYTES: usize = 1_048_576;
const MAX_SKIP_DEPTH: i8 = 64;
const MAX_COLLECTION: usize = 100_000;

/// Reject column chunks whose page headers ask the decoder to allocate too much.
///
/// The official reader allocates `uncompressed_page_size` from the page header
/// before it knows the claim is honest. Walking the compact-protocol headers
/// and refusing oversized pages keeps that allocation from happening.
pub fn preflight_row_groups<R: ChunkReader>(
    reader: &R,
    metadata: &ParquetMetaData,
    row_groups: &[usize],
    root_columns: usize,
) -> std::result::Result<(), PreviewError> {
    let schema = metadata.file_metadata().schema_descr();
    let mut uncompressed_total: u64 = 0;
    for &group_index in row_groups {
        let group = metadata.row_group(group_index);
        for leaf in 0..group.num_columns() {
            if schema.get_column_root_idx(leaf) >= root_columns {
                continue;
            }
            let column = group.column(leaf);
            if column.file_path().is_some() {
                return Err(PreviewError::Decode);
            }
            uncompressed_total =
                uncompressed_total.saturating_add(nonnegative(column.uncompressed_size())?);
            if uncompressed_total > HARD_MAX_UNCOMPRESSED {
                return Err(PreviewError::MemoryLimit);
            }
            check_column_chunk(reader, column, HARD_MAX_UNCOMPRESSED)?;
        }
    }
    Ok(())
}

/// Check one row group before streaming it. The cumulative cap applies only
/// inside this group, so a later group can still be read after an earlier one.
pub(crate) fn preflight_one_group<R: ChunkReader>(
    reader: &R,
    metadata: &ParquetMetaData,
    group_index: usize,
    root_columns: usize,
    max_uncompressed: u64,
    max_compressed_chunk: u64,
) -> std::result::Result<(), PreviewError> {
    let schema = metadata.file_metadata().schema_descr();
    let group = metadata.row_group(group_index);
    let mut uncompressed_total: u64 = 0;
    for leaf in 0..group.num_columns() {
        if schema.get_column_root_idx(leaf) >= root_columns {
            continue;
        }
        let column = group.column(leaf);
        if column.file_path().is_some() {
            return Err(PreviewError::Decode);
        }
        uncompressed_total = uncompressed_total.saturating_add(nonnegative(column.uncompressed_size())?);
        if uncompressed_total > max_uncompressed {
            return Err(PreviewError::MemoryLimit);
        }
        check_column_chunk(reader, column, max_compressed_chunk)?;
    }
    Ok(())
}

fn nonnegative(value: i64) -> std::result::Result<u64, PreviewError> {
    u64::try_from(value).map_err(|_| PreviewError::Decode)
}

fn check_column_chunk<R: ChunkReader>(
    reader: &R,
    column: &ColumnChunkMetaData,
    max_compressed: u64,
) -> std::result::Result<(), PreviewError> {
    let compressed = nonnegative(column.compressed_size())?;
    if compressed == 0 {
        return Ok(());
    }
    if compressed > max_compressed {
        return Err(PreviewError::MemoryLimit);
    }
    let start = column
        .dictionary_page_offset()
        .unwrap_or_else(|| column.data_page_offset());
    let start = nonnegative(start)?;
    let length = usize::try_from(compressed).map_err(|_| PreviewError::Decode)?;
    let bytes = reader.get_bytes(start, length).map_err(map_reader_error)?;
    walk_pages(&bytes, max_compressed)
}

fn map_reader_error(error: parquet::errors::ParquetError) -> PreviewError {
    let text = error.to_string();
    if text.contains("byte limit") {
        PreviewError::ByteLimit
    } else if text.contains("timed out") {
        PreviewError::Timeout
    } else {
        PreviewError::Decode
    }
}

fn walk_pages(chunk: &[u8], max_uncompressed_sum: u64) -> std::result::Result<(), PreviewError> {
    let mut cursor = Cursor::new(chunk);
    let mut pages = 0usize;
    let mut uncompressed_sum: u64 = 0;
    while !cursor.done() {
        pages += 1;
        if pages > MAX_PAGES {
            return Err(PreviewError::PageTooLarge);
        }
        let header_start = cursor.pos;
        let (uncompressed, compressed) = read_page_header(&mut cursor)?;
        if cursor.pos - header_start > MAX_HEADER_BYTES {
            return Err(PreviewError::PageTooLarge);
        }
        if uncompressed > HARD_MAX_PAGE_UNCOMPRESSED {
            return Err(PreviewError::PageTooLarge);
        }
        uncompressed_sum = uncompressed_sum.saturating_add(uncompressed);
        if uncompressed_sum > max_uncompressed_sum {
            return Err(PreviewError::MemoryLimit);
        }
        let compressed = usize::try_from(compressed).map_err(|_| PreviewError::Decode)?;
        cursor.skip(compressed)?;
    }
    Ok(())
}

struct Cursor<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    fn done(&self) -> bool {
        self.pos >= self.buf.len()
    }

    fn remaining(&self) -> usize {
        self.buf.len().saturating_sub(self.pos)
    }

    fn read_u8(&mut self) -> std::result::Result<u8, PreviewError> {
        let byte = *self.buf.get(self.pos).ok_or(PreviewError::Decode)?;
        self.pos += 1;
        Ok(byte)
    }

    fn skip(&mut self, len: usize) -> std::result::Result<(), PreviewError> {
        if len > self.remaining() {
            return Err(PreviewError::Decode);
        }
        self.pos += len;
        Ok(())
    }

    fn read_vlq(&mut self) -> std::result::Result<u64, PreviewError> {
        let mut value: u64 = 0;
        let mut shift = 0;
        loop {
            if shift > 63 {
                return Err(PreviewError::Decode);
            }
            let byte = self.read_u8()?;
            value |= u64::from(byte & 0x7f) << shift;
            if byte & 0x80 == 0 {
                return Ok(value);
            }
            shift += 7;
        }
    }

    fn read_zigzag_i64(&mut self) -> std::result::Result<i64, PreviewError> {
        let value = self.read_vlq()?;
        Ok(((value >> 1) as i64) ^ -((value & 1) as i64))
    }
}

fn read_page_header(cursor: &mut Cursor<'_>) -> std::result::Result<(u64, u64), PreviewError> {
    let mut last_id: i16 = 0;
    let mut uncompressed: Option<i64> = None;
    let mut compressed: Option<i64> = None;
    loop {
        let (field_type, field_id) = read_field_begin(cursor, last_id)?;
        if field_type == FIELD_STOP {
            break;
        }
        last_id = field_id;
        match field_id {
            2 if field_type == FIELD_I32 => uncompressed = Some(cursor.read_zigzag_i64()?),
            3 if field_type == FIELD_I32 => compressed = Some(cursor.read_zigzag_i64()?),
            _ => skip_type(cursor, field_type, MAX_SKIP_DEPTH)?,
        }
    }
    let uncompressed = uncompressed.ok_or(PreviewError::Decode)?;
    let compressed = compressed.ok_or(PreviewError::Decode)?;
    if uncompressed < 0 || compressed < 0 {
        return Err(PreviewError::Decode);
    }
    Ok((uncompressed as u64, compressed as u64))
}

const FIELD_STOP: u8 = 0;
const FIELD_TRUE: u8 = 1;
const FIELD_FALSE: u8 = 2;
const FIELD_BYTE: u8 = 3;
const FIELD_I16: u8 = 4;
const FIELD_I32: u8 = 5;
const FIELD_I64: u8 = 6;
const FIELD_DOUBLE: u8 = 7;
const FIELD_BINARY: u8 = 8;
const FIELD_LIST: u8 = 9;
const FIELD_SET: u8 = 10;
const FIELD_MAP: u8 = 11;
const FIELD_STRUCT: u8 = 12;
const FIELD_UUID: u8 = 13;

fn read_field_begin(
    cursor: &mut Cursor<'_>,
    last_id: i16,
) -> std::result::Result<(u8, i16), PreviewError> {
    let header = cursor.read_u8()?;
    let field_type = header & 0x0f;
    if field_type == FIELD_STOP {
        return Ok((FIELD_STOP, 0));
    }
    let delta = header >> 4;
    let id = if delta == 0 {
        i16::try_from(cursor.read_zigzag_i64()?).map_err(|_| PreviewError::Decode)?
    } else {
        last_id
            .checked_add(i16::from(delta))
            .ok_or(PreviewError::Decode)?
    };
    Ok((field_type, id))
}

fn skip_type(
    cursor: &mut Cursor<'_>,
    field_type: u8,
    depth: i8,
) -> std::result::Result<(), PreviewError> {
    if depth <= 0 {
        return Err(PreviewError::Decode);
    }
    match field_type {
        FIELD_TRUE | FIELD_FALSE | FIELD_STOP => Ok(()),
        FIELD_BYTE => {
            cursor.read_u8()?;
            Ok(())
        }
        FIELD_I16 | FIELD_I32 | FIELD_I64 => {
            cursor.read_vlq()?;
            Ok(())
        }
        FIELD_DOUBLE => cursor.skip(8),
        FIELD_BINARY => {
            let len = usize::try_from(cursor.read_vlq()?).map_err(|_| PreviewError::Decode)?;
            if len > cursor.remaining() {
                return Err(PreviewError::Decode);
            }
            cursor.skip(len)
        }
        FIELD_STRUCT => {
            let mut last = 0i16;
            loop {
                let (inner, id) = read_field_begin(cursor, last)?;
                if inner == FIELD_STOP {
                    break;
                }
                last = id;
                skip_type(cursor, inner, depth - 1)?;
            }
            Ok(())
        }
        FIELD_LIST | FIELD_SET => skip_list(cursor, depth),
        FIELD_MAP => skip_map(cursor, depth),
        FIELD_UUID => cursor.skip(16),
        _ => Err(PreviewError::Decode),
    }
}

fn skip_list(cursor: &mut Cursor<'_>, depth: i8) -> std::result::Result<(), PreviewError> {
    let header = cursor.read_u8()?;
    if header == 0 {
        return Ok(());
    }
    let element_type = header & 0x0f;
    let mut size = usize::from(header >> 4);
    if size == 15 {
        size = usize::try_from(cursor.read_vlq()?).map_err(|_| PreviewError::Decode)?;
    }
    if size > MAX_COLLECTION || size > cursor.remaining().saturating_add(1) {
        return Err(PreviewError::PageTooLarge);
    }
    for _ in 0..size {
        if element_type == 1 || element_type == 2 {
            // Boolean list elements are a byte. Struct-field booleans are not.
            cursor.read_u8()?;
        } else {
            skip_type(cursor, element_type, depth - 1)?;
        }
    }
    Ok(())
}

fn skip_map(cursor: &mut Cursor<'_>, depth: i8) -> std::result::Result<(), PreviewError> {
    let size = usize::try_from(cursor.read_vlq()?).map_err(|_| PreviewError::Decode)?;
    if size == 0 {
        return Ok(());
    }
    if size > MAX_COLLECTION {
        return Err(PreviewError::PageTooLarge);
    }
    let kinds = cursor.read_u8()?;
    let key_type = kinds >> 4;
    let val_type = kinds & 0x0f;
    for _ in 0..size {
        skip_type(cursor, key_type, depth - 1)?;
        skip_type(cursor, val_type, depth - 1)?;
    }
    Ok(())
}

pub fn select_row_groups(metadata: &ParquetMetaData, max_rows: u32) -> Vec<usize> {
    let mut selected = Vec::new();
    let mut rows_needed = u64::from(max_rows);
    for index in 0..metadata.num_row_groups() {
        if rows_needed == 0 {
            break;
        }
        let group: &RowGroupMetaData = metadata.row_group(index);
        selected.push(index);
        let rows = group.num_rows().max(0) as u64;
        rows_needed = rows_needed.saturating_sub(rows);
    }
    selected
}

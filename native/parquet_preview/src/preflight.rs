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

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::sync::Arc;

    use arrow_array::{Int64Array, RecordBatch};
    use arrow_schema::{DataType, Field, Schema};
    use parquet::arrow::ArrowWriter;
    use parquet::errors::ParquetError;
    use parquet::file::metadata::ParquetMetaDataReader;
    use parquet::file::properties::WriterProperties;

    fn push_vlq(buf: &mut Vec<u8>, mut value: u64) {
        loop {
            let mut byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            buf.push(byte);
            if value == 0 {
                break;
            }
        }
    }

    fn zigzag(value: i64) -> u64 {
        ((value << 1) ^ (value >> 63)) as u64
    }

    fn i32_field(delta: u8, value: i64) -> Vec<u8> {
        let mut buf = vec![(delta << 4) | FIELD_I32];
        push_vlq(&mut buf, zigzag(value));
        buf
    }

    fn page(uncompressed: i64, compressed: i64, payload: usize) -> Vec<u8> {
        let mut buf = i32_field(2, uncompressed);
        buf.extend(i32_field(1, compressed));
        buf.push(FIELD_STOP);
        buf.extend(std::iter::repeat_n(0, payload));
        buf
    }

    #[test]
    fn page_walker_rejects_limits_and_bad_headers() {
        assert!(walk_pages(&page(10, 4, 4), u64::MAX).is_ok());
        assert_eq!(
            walk_pages(&page(HARD_MAX_PAGE_UNCOMPRESSED as i64 + 1, 0, 0), u64::MAX).unwrap_err(),
            PreviewError::PageTooLarge
        );
        assert_eq!(walk_pages(&page(100, 0, 0), 50).unwrap_err(), PreviewError::MemoryLimit);
        assert_eq!(walk_pages(&page(10, 20, 2), u64::MAX).unwrap_err(), PreviewError::Decode);
        assert_eq!(walk_pages(&page(-1, 1, 0), u64::MAX).unwrap_err(), PreviewError::Decode);

        let one = page(1, 0, 0);
        let mut many = Vec::new();
        for _ in 0..=MAX_PAGES {
            many.extend_from_slice(&one);
        }
        assert_eq!(walk_pages(&many, u64::MAX).unwrap_err(), PreviewError::PageTooLarge);

        let mut huge = vec![(1 << 4) | FIELD_BINARY];
        push_vlq(&mut huge, MAX_HEADER_BYTES as u64);
        huge.extend(std::iter::repeat_n(0, MAX_HEADER_BYTES));
        huge.extend(i32_field(1, 1));
        huge.extend(i32_field(1, 0));
        huge.push(FIELD_STOP);
        assert_eq!(walk_pages(&huge, u64::MAX).unwrap_err(), PreviewError::PageTooLarge);

        let mut overflow = vec![FIELD_I32];
        push_vlq(&mut overflow, zigzag(40_000));
        let mut cursor = Cursor::new(&overflow);
        assert_eq!(read_field_begin(&mut cursor, 0).unwrap_err(), PreviewError::Decode);

        let mut wide = Cursor::new(&[0x80; 10]);
        assert_eq!(wide.read_vlq().unwrap_err(), PreviewError::Decode);
        let mut short = Cursor::new(&[1, 2]);
        assert_eq!(short.skip(3).unwrap_err(), PreviewError::Decode);
    }

    #[test]
    fn skipped_thrift_values_cover_each_type() {
        let samples: Vec<(u8, Vec<u8>, bool)> = vec![
            (FIELD_TRUE, vec![], true),
            (FIELD_BYTE, vec![0x7f], true),
            (FIELD_DOUBLE, vec![0; 8], true),
            (FIELD_BINARY, vec![1, 0xaa], true),
            (FIELD_BINARY, vec![50], false),
            (FIELD_UUID, vec![0; 16], true),
            (14, vec![], false),
            (FIELD_LIST, vec![0], true),
            (FIELD_LIST, vec![(2 << 4) | 1, 1, 0], true),
            (FIELD_LIST, {
                let mut body = vec![(15 << 4) | FIELD_BYTE];
                push_vlq(&mut body, 1);
                body.push(0xab);
                body
            }, true),
            (FIELD_LIST, {
                let mut body = vec![(15 << 4) | FIELD_BYTE];
                push_vlq(&mut body, (MAX_COLLECTION as u64) + 1);
                body
            }, false),
            (FIELD_SET, vec![0], true),
            (FIELD_MAP, vec![0], true),
            (FIELD_MAP, vec![1, (FIELD_BYTE << 4) | FIELD_BYTE, 1, 2], true),
            (FIELD_MAP, {
                let mut body = Vec::new();
                push_vlq(&mut body, (MAX_COLLECTION as u64) + 1);
                body
            }, false),
        ];
        for (kind, body, ok) in samples {
            let mut cursor = Cursor::new(&body);
            let result = skip_type(&mut cursor, kind, MAX_SKIP_DEPTH);
            assert_eq!(result.is_ok(), ok, "type {kind}");
        }

        let mut nested = Vec::new();
        for _ in 0..=MAX_SKIP_DEPTH {
            nested.push((1 << 4) | FIELD_STRUCT);
        }
        let mut cursor = Cursor::new(&nested);
        assert_eq!(
            skip_type(&mut cursor, FIELD_STRUCT, MAX_SKIP_DEPTH).unwrap_err(),
            PreviewError::Decode
        );
    }

    #[test]
    fn reader_errors_keep_their_names() {
        assert_eq!(
            map_reader_error(ParquetError::General("byte limit".into())),
            PreviewError::ByteLimit
        );
        assert_eq!(
            map_reader_error(ParquetError::General("timed out".into())),
            PreviewError::Timeout
        );
        assert_eq!(
            map_reader_error(ParquetError::General("nope".into())),
            PreviewError::Decode
        );
    }

    #[test]
    fn group_caps_stop_a_real_file_and_later_groups_are_not_required() {
        let dir = std::env::temp_dir().join(format!("parquet-preflight-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("two.parquet");
        let schema = Arc::new(Schema::new(vec![Field::new("id", DataType::Int64, true)]));
        let batch = RecordBatch::try_new(
            Arc::clone(&schema),
            vec![Arc::new(Int64Array::from(vec![Some(1), Some(2)])) as _],
        )
        .unwrap();
        let props = WriterProperties::builder()
            .set_max_row_group_row_count(Some(1))
            .build();
        let mut writer = ArrowWriter::try_new(File::create(&path).unwrap(), schema, Some(props)).unwrap();
        writer.write(&batch).unwrap();
        writer.close().unwrap();

        let file = File::open(&path).unwrap();
        let metadata = ParquetMetaDataReader::new().parse_and_finish(&file).unwrap();
        assert!(metadata.num_row_groups() >= 2);
        assert_eq!(select_row_groups(&metadata, 1), vec![0]);
        assert_eq!(
            preflight_one_group(&file, &metadata, 0, 1, 0, u64::MAX).unwrap_err(),
            PreviewError::MemoryLimit
        );
        assert_eq!(
            preflight_one_group(&file, &metadata, 0, 1, u64::MAX, 0).unwrap_err(),
            PreviewError::MemoryLimit
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}

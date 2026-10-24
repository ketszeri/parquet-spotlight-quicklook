use std::fmt::Write as _;

use arrow_array::cast::AsArray;
use arrow_buffer::ArrowNativeType;
use arrow_array::types::{
    Date32Type, Date64Type, Decimal128Type, Decimal256Type, Float32Type, Float64Type, Int16Type,
    Int32Type, Int64Type, Int8Type, TimestampMicrosecondType, TimestampMillisecondType,
    TimestampNanosecondType, TimestampSecondType, UInt16Type, UInt32Type, UInt64Type, UInt8Type,
};
use arrow_array::{Array, ArrayRef, DictionaryArray};
use arrow_schema::extension::{ExtensionType, Uuid};
use arrow_schema::{DataType, Field, TimeUnit};

use crate::limits::{DISPLAY_CHARS, MAX_NESTED_ITEMS, TITLE_CHARS, TITLE_NESTED_ITEMS};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cell {
    pub text: Option<String>,
    pub truncated: bool,
    pub title: Option<String>,
}

impl Cell {
    fn null() -> Self {
        Self {
            text: None,
            truncated: false,
            title: None,
        }
    }
}

struct Style {
    max_chars: usize,
    max_items: usize,
}

pub fn format_cell(field: &Field, array: &ArrayRef, row: usize) -> Cell {
    if array.is_null(row) || array.len() <= row {
        return Cell::null();
    }
    let display = render_value(field, array.as_ref(), row, &Style {
        max_chars: DISPLAY_CHARS.saturating_mul(4),
        max_items: MAX_NESTED_ITEMS,
    });
    let full = render_value(field, array.as_ref(), row, &Style {
        max_chars: TITLE_CHARS.saturating_mul(2),
        max_items: TITLE_NESTED_ITEMS,
    });
    clip_cell(&display.text, display.truncated, &full.text)
}

struct Rendered {
    text: String,
    truncated: bool,
}

fn render_value(field: &Field, array: &dyn Array, row: usize, style: &Style) -> Rendered {
    if array.is_null(row) {
        return Rendered {
            text: "null".to_string(),
            truncated: false,
        };
    }
    let mut out = String::new();
    let truncated = write_value(&mut out, field, array, row, style, 0);
    Rendered {
        text: out,
        truncated,
    }
}

fn write_value(
    out: &mut String,
    field: &Field,
    array: &dyn Array,
    row: usize,
    style: &Style,
    depth: usize,
) -> bool {
    if out.chars().count() >= style.max_chars {
        return true;
    }
    if depth > 6 {
        let _ = out.write_str("…");
        return true;
    }
    if array.is_null(row) {
        let _ = out.write_str("null");
        return false;
    }
    match array.data_type() {
        DataType::Dictionary(_, _) => write_dictionary(out, field, array, row, style, depth),
        DataType::Boolean => {
            push_plain(out, if array.as_boolean().value(row) { "true" } else { "false" });
            false
        }
        DataType::Int8 => push_plain(out, &array.as_primitive::<Int8Type>().value(row).to_string()),
        DataType::Int16 => push_plain(out, &array.as_primitive::<Int16Type>().value(row).to_string()),
        DataType::Int32 => push_plain(out, &array.as_primitive::<Int32Type>().value(row).to_string()),
        DataType::Int64 => push_plain(out, &array.as_primitive::<Int64Type>().value(row).to_string()),
        DataType::UInt8 => push_plain(out, &array.as_primitive::<UInt8Type>().value(row).to_string()),
        DataType::UInt16 => {
            push_plain(out, &array.as_primitive::<UInt16Type>().value(row).to_string())
        }
        DataType::UInt32 => {
            push_plain(out, &array.as_primitive::<UInt32Type>().value(row).to_string())
        }
        DataType::UInt64 => {
            push_plain(out, &array.as_primitive::<UInt64Type>().value(row).to_string())
        }
        DataType::Float32 => push_number(out, array.as_primitive::<Float32Type>().value(row) as f64),
        DataType::Float64 => push_number(out, array.as_primitive::<Float64Type>().value(row)),
        DataType::Utf8 => push_top_string(out, array.as_string::<i32>().value(row)),
        DataType::LargeUtf8 => push_top_string(out, array.as_string::<i64>().value(row)),
        DataType::Date32 => {
            push_plain(out, &format_date32(array.as_primitive::<Date32Type>().value(row)));
            false
        }
        DataType::Date64 => {
            push_plain(out, &format_date64(array.as_primitive::<Date64Type>().value(row)));
            false
        }
        DataType::Timestamp(unit, _) => {
            let ticks = timestamp_ticks(array, row, *unit);
            push_plain(out, &format_timestamp(ticks, *unit));
            false
        }
        DataType::Decimal128(_, scale) => {
            let value = array.as_primitive::<Decimal128Type>().value(row);
            push_plain(out, &format_decimal_i128(value, *scale));
            false
        }
        DataType::Decimal256(_, scale) => {
            let value = array.as_primitive::<Decimal256Type>().value(row);
            push_plain(out, &format_decimal_i256(value, *scale));
            false
        }
        DataType::Binary => push_bytes(out, array.as_binary::<i32>().value(row)),
        DataType::LargeBinary => push_bytes(out, array.as_binary::<i64>().value(row)),
        DataType::FixedSizeBinary(_) => {
            let bytes = array.as_fixed_size_binary().value(row);
            if is_uuid(field) && bytes.len() == 16 {
                push_plain(out, &format_uuid(bytes));
                false
            } else {
                push_bytes(out, bytes)
            }
        }
        DataType::List(_) | DataType::LargeList(_) => {
            write_list(out, field, array, row, style, depth)
        }
        DataType::Struct(_) => write_struct(out, array, row, style, depth, false),
        DataType::Map(_, _) => write_map(out, array, row, style, depth),
        DataType::Null => {
            let _ = out.write_str("null");
            false
        }
        other => {
            let _ = write!(out, "<{other}>");
            false
        }
    }
}

fn push_plain(out: &mut String, text: &str) -> bool {
    let _ = out.write_str(text);
    false
}

fn push_number(out: &mut String, value: f64) -> bool {
    if value.is_finite() {
        let _ = write!(out, "{value}");
    } else if value.is_nan() {
        let _ = out.write_str("NaN");
    } else if value.is_sign_negative() {
        let _ = out.write_str("-Infinity");
    } else {
        let _ = out.write_str("Infinity");
    }
    false
}

fn push_top_string(out: &mut String, value: &str) -> bool {
    let _ = out.write_str(&sanitize(value));
    false
}

fn write_dictionary(
    out: &mut String,
    field: &Field,
    array: &dyn Array,
    row: usize,
    style: &Style,
    depth: usize,
) -> bool {
    macro_rules! arm {
        ($($ty:ty),*) => {
            $(
                if let Some(dict) = array.as_any().downcast_ref::<DictionaryArray<$ty>>() {
                    if dict.is_null(row) {
                        let _ = out.write_str("null");
                        return false;
                    }
                    let key = dict.keys().value(row).as_usize();
                    return write_value(out, field, dict.values().as_ref(), key, style, depth);
                }
            )*
        };
    }
    arm!(Int8Type, Int16Type, Int32Type, Int64Type, UInt8Type, UInt16Type, UInt32Type, UInt64Type);
    let _ = out.write_str("<dictionary>");
    true
}

fn write_list(
    out: &mut String,
    field: &Field,
    array: &dyn Array,
    row: usize,
    style: &Style,
    depth: usize,
) -> bool {
    let (values, start, end, child_field) = match array.data_type() {
        DataType::List(child) => {
            let list = array.as_list::<i32>();
            let offsets = list.value_offsets();
            (
                list.values(),
                offsets[row] as usize,
                offsets[row + 1] as usize,
                child.as_ref().clone(),
            )
        }
        DataType::LargeList(child) => {
            let list = array.as_list::<i64>();
            let offsets = list.value_offsets();
            (
                list.values(),
                offsets[row] as usize,
                offsets[row + 1] as usize,
                child.as_ref().clone(),
            )
        }
        _ => return false,
    };
    // Prefer the nested field from the parent when Arrow's child is generic.
    let child_field = list_child_field(field).unwrap_or(child_field);
    let _ = out.write_char('[');
    let mut truncated = false;
    let count = end.saturating_sub(start);
    let shown = count.min(style.max_items);
    for offset in 0..shown {
        if offset > 0 {
            let _ = out.write_str(", ");
        }
        if out.chars().count() >= style.max_chars {
            truncated = true;
            break;
        }
        let nested = values.is_null(start + offset);
        if nested {
            let _ = out.write_str("null");
        } else if matches!(
            values.data_type(),
            DataType::Utf8 | DataType::LargeUtf8 | DataType::Binary | DataType::LargeBinary
        ) {
            truncated |= write_quoted(out, &child_field, values.as_ref(), start + offset, style, depth + 1);
        } else {
            truncated |= write_value(out, &child_field, values.as_ref(), start + offset, style, depth + 1);
        }
    }
    if count > shown {
        if shown > 0 {
            let _ = out.write_str(", ");
        }
        let _ = out.write_str("…");
        truncated = true;
    }
    let _ = out.write_char(']');
    truncated
}

fn list_child_field(field: &Field) -> Option<Field> {
    match field.data_type() {
        DataType::List(child) | DataType::LargeList(child) => Some(child.as_ref().clone()),
        _ => None,
    }
}

fn write_struct(
    out: &mut String,
    array: &dyn Array,
    row: usize,
    style: &Style,
    depth: usize,
    quote_names: bool,
) -> bool {
    let structure = array.as_struct();
    let fields = structure.fields();
    let columns = structure.columns();
    let _ = out.write_char('{');
    let mut truncated = false;
    let shown = fields.len().min(style.max_items);
    for (index, field) in fields.iter().take(shown).enumerate() {
        if index > 0 {
            let _ = out.write_str(", ");
        }
        if quote_names {
            let _ = write!(out, "{}: ", quote(&sanitize(field.name())));
        } else {
            let _ = write!(out, "{}: ", field.name());
        }
        let column = &columns[index];
        if column.is_null(row) {
            let _ = out.write_str("null");
        } else if is_quoted_leaf(column.data_type()) {
            truncated |= write_quoted(out, field.as_ref(), column.as_ref(), row, style, depth + 1);
        } else {
            truncated |= write_value(out, field.as_ref(), column.as_ref(), row, style, depth + 1);
        }
    }
    if fields.len() > shown {
        let _ = out.write_str(", …");
        truncated = true;
    }
    let _ = out.write_char('}');
    truncated
}

fn write_map(
    out: &mut String,
    array: &dyn Array,
    row: usize,
    style: &Style,
    depth: usize,
) -> bool {
    let map = array.as_map();
    let offsets = map.value_offsets();
    let start = offsets[row] as usize;
    let end = offsets[row + 1] as usize;
    let keys = map.keys();
    let values = map.values();
    let value_field = map_value_field(array.data_type());
    let _ = out.write_char('{');
    let mut truncated = false;
    let count = end.saturating_sub(start);
    let shown = count.min(style.max_items);
    for offset in 0..shown {
        if offset > 0 {
            let _ = out.write_str(", ");
        }
        let key_index = start + offset;
        let key_text = if keys.is_null(key_index) {
            "null".to_string()
        } else {
            let mut key_buf = String::new();
            write_value(
                &mut key_buf,
                &Field::new("key", keys.data_type().clone(), true),
                keys.as_ref(),
                key_index,
                style,
                depth + 1,
            );
            key_buf
        };
        let _ = write!(out, "{}: ", quote(&key_text));
        if values.is_null(key_index) {
            let _ = out.write_str("null");
        } else if is_quoted_leaf(values.data_type()) {
            truncated |= write_quoted(
                out,
                &value_field,
                values.as_ref(),
                key_index,
                style,
                depth + 1,
            );
        } else {
            truncated |= write_value(out, &value_field, values.as_ref(), key_index, style, depth + 1);
        }
    }
    if count > shown {
        if shown > 0 {
            let _ = out.write_str(", ");
        }
        let _ = out.write_str("…");
        truncated = true;
    }
    let _ = out.write_char('}');
    truncated
}

fn map_value_field(data_type: &DataType) -> Field {
    if let DataType::Map(entries, _) = data_type {
        if let DataType::Struct(fields) = entries.data_type() {
            if let Some(value) = fields.get(1) {
                return value.as_ref().clone();
            }
        }
    }
    Field::new("value", DataType::Utf8, true)
}

fn is_quoted_leaf(data_type: &DataType) -> bool {
    matches!(
        data_type,
        DataType::Utf8 | DataType::LargeUtf8 | DataType::Binary | DataType::LargeBinary
    )
}

fn write_quoted(
    out: &mut String,
    field: &Field,
    array: &dyn Array,
    row: usize,
    style: &Style,
    depth: usize,
) -> bool {
    let mut inner = String::new();
    let truncated = write_value(&mut inner, field, array, row, style, depth);
    let _ = write!(out, "{}", quote(&inner));
    truncated
}

fn is_uuid(field: &Field) -> bool {
    field.try_extension_type::<Uuid>().is_ok()
        || field.extension_type_name() == Some(Uuid::NAME)
}

fn timestamp_ticks(array: &dyn Array, row: usize, unit: TimeUnit) -> i64 {
    match unit {
        TimeUnit::Second => array.as_primitive::<TimestampSecondType>().value(row),
        TimeUnit::Millisecond => array.as_primitive::<TimestampMillisecondType>().value(row),
        TimeUnit::Microsecond => array.as_primitive::<TimestampMicrosecondType>().value(row),
        TimeUnit::Nanosecond => array.as_primitive::<TimestampNanosecondType>().value(row),
    }
}

pub fn type_name(field: &Field) -> String {
    if is_uuid(field) {
        return "uuid".to_string();
    }
    type_name_of(field.data_type())
}

fn type_name_of(data_type: &DataType) -> String {
    match data_type {
        DataType::Boolean => "bool".to_string(),
        DataType::Int8 => "int8".to_string(),
        DataType::Int16 => "int16".to_string(),
        DataType::Int32 => "int32".to_string(),
        DataType::Int64 => "int64".to_string(),
        DataType::UInt8 => "uint8".to_string(),
        DataType::UInt16 => "uint16".to_string(),
        DataType::UInt32 => "uint32".to_string(),
        DataType::UInt64 => "uint64".to_string(),
        DataType::Float32 => "float".to_string(),
        DataType::Float64 => "double".to_string(),
        DataType::Utf8 | DataType::LargeUtf8 => "string".to_string(),
        DataType::Binary | DataType::LargeBinary => "binary".to_string(),
        DataType::Date32 | DataType::Date64 => "date".to_string(),
        DataType::Timestamp(unit, tz) => {
            let unit = match unit {
                TimeUnit::Second => "s",
                TimeUnit::Millisecond => "ms",
                TimeUnit::Microsecond => "us",
                TimeUnit::Nanosecond => "ns",
            };
            if tz.is_some() {
                format!("timestamp[{unit}, tz]")
            } else {
                format!("timestamp[{unit}]")
            }
        }
        DataType::Decimal128(precision, scale) | DataType::Decimal256(precision, scale) => {
            format!("decimal({precision},{scale})")
        }
        DataType::List(field) | DataType::LargeList(field) => {
            format!("list<{}>", type_name(field))
        }
        DataType::Struct(fields) => {
            let parts: Vec<String> = fields
                .iter()
                .map(|field| format!("{}: {}", field.name(), type_name(field)))
                .collect();
            format!("struct<{}>", parts.join(", "))
        }
        DataType::Map(entries, _) => {
            if let DataType::Struct(fields) = entries.data_type() {
                if fields.len() >= 2 {
                    return format!("map<{}, {}>", type_name(&fields[0]), type_name(&fields[1]));
                }
            }
            "map".to_string()
        }
        DataType::FixedSizeBinary(16) => "fixed_size_binary(16)".to_string(),
        DataType::FixedSizeBinary(width) => format!("fixed_size_binary({width})"),
        DataType::Dictionary(_, value) => type_name_of(value),
        DataType::Null => "null".to_string(),
        other => other.to_string(),
    }
}

fn clip_cell(display: &str, nested_truncated: bool, fuller: &str) -> Cell {
    let display_chars = display.chars().count();
    let (text, cut) = if display_chars > DISPLAY_CHARS {
        let mut prefix: String = display.chars().take(DISPLAY_CHARS - 1).collect();
        prefix.push('…');
        (prefix, true)
    } else {
        (display.to_string(), false)
    };
    let truncated = nested_truncated || cut || fuller.chars().count() > display.chars().count();
    let title = if truncated {
        let mut title: String = fuller.chars().take(TITLE_CHARS.saturating_sub(1)).collect();
        if fuller.chars().count() > title.chars().count() {
            title.push('…');
        }
        if title != text {
            Some(title)
        } else {
            None
        }
    } else {
        None
    };
    Cell {
        text: Some(text),
        truncated,
        title,
    }
}

fn sanitize(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{0000}' => out.push_str("\\0"),
            c if c.is_control() => {
                let _ = write!(out, "\\u{{{:x}}}", u32::from(c));
            }
            c => out.push(c),
        }
    }
    out
}

fn quote(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for ch in value.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn push_bytes(out: &mut String, bytes: &[u8]) -> bool {
    if let Ok(text) = std::str::from_utf8(bytes) {
        if !text.chars().any(|ch| ch.is_control() && ch != '\t') {
            let _ = out.write_str(&sanitize(text));
            return false;
        }
    }
    let _ = out.write_str("0x");
    for byte in bytes.iter().take(64) {
        let _ = write!(out, "{byte:02x}");
    }
    if bytes.len() > 64 {
        let _ = out.write_str("…");
        return true;
    }
    false
}

fn format_uuid(bytes: &[u8]) -> String {
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

fn format_decimal_i128(value: i128, scale: i8) -> String {
    format_decimal_digits(&value.unsigned_abs().to_string(), value < 0, scale)
}

fn format_decimal_i256(value: arrow_buffer::i256, scale: i8) -> String {
    let text = value.to_string();
    let (negative, digits) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text.as_str()),
    };
    format_decimal_digits(digits, negative, scale)
}

fn format_decimal_digits(digits: &str, negative: bool, scale: i8) -> String {
    let scale = i32::from(scale).max(0) as usize;
    let body = if scale == 0 {
        digits.to_string()
    } else if digits.len() > scale {
        let split = digits.len() - scale;
        format!("{}.{}", &digits[..split], &digits[split..])
    } else {
        let zeros = "0".repeat(scale - digits.len());
        format!("0.{}{}", zeros, digits)
    };
    if negative && body != "0" && !body.starts_with("0.000") {
        format!("-{body}")
    } else if negative && body.chars().any(|ch| ch != '0' && ch != '.') {
        format!("-{body}")
    } else {
        body
    }
}

pub(crate) fn format_date32(days: i32) -> String {
    format_civil_date(i64::from(days))
}

fn format_date64(millis: i64) -> String {
    format_civil_date(millis.div_euclid(86_400_000))
}

pub(crate) fn format_timestamp(ticks: i64, unit: TimeUnit) -> String {
    let (seconds, nanos) = match unit {
        TimeUnit::Second => (ticks, 0i64),
        TimeUnit::Millisecond => {
            let seconds = ticks.div_euclid(1_000);
            let millis = ticks.rem_euclid(1_000);
            (seconds, millis * 1_000_000)
        }
        TimeUnit::Microsecond => {
            let seconds = ticks.div_euclid(1_000_000);
            let micros = ticks.rem_euclid(1_000_000);
            (seconds, micros * 1_000)
        }
        TimeUnit::Nanosecond => {
            let seconds = ticks.div_euclid(1_000_000_000);
            let nanos = ticks.rem_euclid(1_000_000_000);
            (seconds, nanos)
        }
    };
    let days = seconds.div_euclid(86_400);
    let tod = seconds.rem_euclid(86_400) as u32;
    let hour = tod / 3600;
    let minute = (tod % 3600) / 60;
    let second = tod % 60;
    let date = format_civil_date(days);
    if nanos == 0 {
        format!("{date}T{hour:02}:{minute:02}:{second:02}Z")
    } else {
        let fraction = format!("{nanos:09}").trim_end_matches('0').to_string();
        format!("{date}T{hour:02}:{minute:02}:{second:02}.{fraction}Z")
    }
}

/// Howard Hinnant's `civil_from_days`, days relative to Unix epoch.
fn format_civil_date(days: i64) -> String {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { y + 1 } else { y };
    format!("{year:04}-{month:02}-{day:02}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use arrow_array::builder::{Int32Builder, LargeListBuilder};
    use arrow_array::{
        BinaryArray, BooleanArray, Date64Array, Decimal256Array, FixedSizeBinaryArray, Float32Array,
        Float64Array, Int16Array, Int32Array, Int8Array, LargeBinaryArray, LargeStringArray, NullArray,
        StringArray, StructArray, TimestampNanosecondArray, TimestampSecondArray, UInt16Array,
        UInt32Array, UInt8Array, UInt64Array,
    };
    use arrow_buffer::i256;

    fn cell(name: &str, data_type: DataType, array: ArrayRef) -> Cell {
        format_cell(&Field::new(name, data_type, true), &array, 0)
    }

    #[test]
    fn physical_types_outside_the_fixtures_still_render() {
        assert_eq!(
            cell("b", DataType::Boolean, Arc::new(BooleanArray::from(vec![Some(false)]))).text.as_deref(),
            Some("false")
        );
        assert!(format_cell(
            &Field::new("b", DataType::Boolean, true),
            &(Arc::new(BooleanArray::from(vec![Some(true)])) as ArrayRef),
            4
        ).text.is_none());
        assert_eq!(cell("i8", DataType::Int8, Arc::new(Int8Array::from(vec![Some(-3)]))).text.as_deref(), Some("-3"));
        assert_eq!(cell("i16", DataType::Int16, Arc::new(Int16Array::from(vec![Some(12)]))).text.as_deref(), Some("12"));
        assert_eq!(cell("u8", DataType::UInt8, Arc::new(UInt8Array::from(vec![Some(7u8)]))).text.as_deref(), Some("7"));
        assert_eq!(cell("u16", DataType::UInt16, Arc::new(UInt16Array::from(vec![Some(8u16)]))).text.as_deref(), Some("8"));
        assert_eq!(cell("u32", DataType::UInt32, Arc::new(UInt32Array::from(vec![Some(9u32)]))).text.as_deref(), Some("9"));
        assert_eq!(cell("u64", DataType::UInt64, Arc::new(UInt64Array::from(vec![Some(10u64)]))).text.as_deref(), Some("10"));

        let floats = Arc::new(Float64Array::from(vec![Some(f64::NAN), Some(f64::INFINITY), Some(f64::NEG_INFINITY)])) as ArrayRef;
        let field = Field::new("f", DataType::Float64, true);
        assert_eq!(format_cell(&field, &floats, 0).text.as_deref(), Some("NaN"));
        assert_eq!(format_cell(&field, &floats, 1).text.as_deref(), Some("Infinity"));
        assert_eq!(format_cell(&field, &floats, 2).text.as_deref(), Some("-Infinity"));
        assert_eq!(
            cell("f32", DataType::Float32, Arc::new(Float32Array::from(vec![Some(1.5f32)]))).text.as_deref(),
            Some("1.5")
        );
        let wide = cell("s", DataType::LargeUtf8, Arc::new(LargeStringArray::from(vec![Some("plain")])));
        assert_eq!(wide.text.as_deref(), Some("plain"));
        let dated = cell("d", DataType::Date64, Arc::new(Date64Array::from(vec![Some(0i64)])));
        assert_eq!(dated.text.as_deref(), Some("1970-01-01"));
        let seconds = cell(
            "ts",
            DataType::Timestamp(TimeUnit::Second, None),
            Arc::new(TimestampSecondArray::from(vec![Some(1_577_934_245)])),
        );
        assert!(seconds.text.as_deref().unwrap().starts_with("2020-01-02T"), "{seconds:?}");
        let nanos = cell(
            "ns",
            DataType::Timestamp(TimeUnit::Nanosecond, None),
            Arc::new(TimestampNanosecondArray::from(vec![Some(1_500)])),
        );
        assert!(nanos.text.as_deref().unwrap().contains('.'), "{nanos:?}");

        let decimal = Decimal256Array::from(vec![Some(i256::from(1250))])
            .with_precision_and_scale(10, 2)
            .unwrap();
        let amount = cell("dec", DataType::Decimal256(10, 2), Arc::new(decimal));
        assert_eq!(amount.text.as_deref(), Some("12.50"));

        let bytes = cell("bin", DataType::Binary, Arc::new(BinaryArray::from(vec![Some(&b"ab"[..])])));
        let rendered = bytes.text.as_deref().unwrap();
        assert!(rendered.contains("ab") || rendered.contains("61"), "{bytes:?}");
        let large = cell("lb", DataType::LargeBinary, Arc::new(LargeBinaryArray::from(vec![Some(&b"cd"[..])])));
        assert!(large.text.is_some());
        let fixed = FixedSizeBinaryArray::try_from_sparse_iter_with_size(
            [Some(&b"abcd"[..])].into_iter(),
            4,
        )
        .unwrap();
        let raw = cell("fx", DataType::FixedSizeBinary(4), Arc::new(fixed));
        assert!(raw.text.is_some());

        let nulls = cell("z", DataType::Null, Arc::new(NullArray::new(1)));
        assert_eq!(nulls.text.as_deref(), Some("null"));

        let keys = UInt8Array::from(vec![Some(0u8), None]);
        let values = StringArray::from(vec![Some("red")]);
        let dict = DictionaryArray::try_new(keys, Arc::new(values) as ArrayRef).unwrap();
        let dict_field = Field::new("code", DataType::Dictionary(Box::new(DataType::UInt8), Box::new(DataType::Utf8)), true);
        let dict = Arc::new(dict) as ArrayRef;
        assert_eq!(format_cell(&dict_field, &dict, 0).text.as_deref(), Some("red"));
        assert!(format_cell(&dict_field, &dict, 1).text.is_none());

        let mut lists = LargeListBuilder::new(Int32Builder::new());
        lists.values().append_value(1);
        lists.values().append_null();
        lists.append(true);
        let list = lists.finish();
        let nested = cell("xs", DataType::LargeList(Arc::new(Field::new("item", DataType::Int32, true))), Arc::new(list));
        assert!(nested.text.as_deref().unwrap().starts_with('['), "{nested:?}");
    }

    #[test]
    fn names_escapes_and_nested_limits_render() {
        assert_eq!(type_name(&Field::new("a", DataType::Int8, true)), "int8");
        assert_eq!(type_name(&Field::new("a", DataType::Int16, true)), "int16");
        assert_eq!(type_name(&Field::new("a", DataType::UInt8, true)), "uint8");
        assert_eq!(type_name(&Field::new("a", DataType::UInt16, true)), "uint16");
        assert_eq!(type_name(&Field::new("a", DataType::UInt32, true)), "uint32");
        assert_eq!(type_name(&Field::new("a", DataType::UInt64, true)), "uint64");
        assert_eq!(type_name(&Field::new("a", DataType::Binary, true)), "binary");
        assert_eq!(
            type_name(&Field::new("a", DataType::Timestamp(TimeUnit::Millisecond, None), true)),
            "timestamp[ms]"
        );
        assert_eq!(
            type_name(&Field::new(
                "a",
                DataType::Timestamp(TimeUnit::Microsecond, Some("UTC".into())),
                true
            )),
            "timestamp[us, tz]"
        );
        assert_eq!(
            type_name(&Field::new("a", DataType::Timestamp(TimeUnit::Second, None), true)),
            "timestamp[s]"
        );
        assert_eq!(
            type_name(&Field::new("a", DataType::Timestamp(TimeUnit::Nanosecond, None), true)),
            "timestamp[ns]"
        );
        assert_eq!(type_name(&Field::new("a", DataType::FixedSizeBinary(16), true)), "fixed_size_binary(16)");
        assert_eq!(type_name(&Field::new("a", DataType::FixedSizeBinary(4), true)), "fixed_size_binary(4)");
        assert_eq!(
            type_name(&Field::new(
                "a",
                DataType::Dictionary(Box::new(DataType::Int32), Box::new(DataType::Utf8)),
                true
            )),
            "string"
        );
        assert_eq!(type_name(&Field::new("a", DataType::Null, true)), "null");
        assert_eq!(type_name(&Field::new("a", DataType::Decimal128(10, 2), true)), "decimal(10,2)");
        let weird_map = DataType::Map(Arc::new(Field::new("entries", DataType::Utf8, false)), false);
        assert_eq!(type_name(&Field::new("m", weird_map, true)), "map");

        let escaped = cell(
            "s",
            DataType::Utf8,
            Arc::new(StringArray::from(vec![Some("a\nb\tc\r\0\u{1}")])),
        );
        let escaped = escaped.text.unwrap();
        assert!(escaped.contains("\\n") && escaped.contains("\\0") && escaped.contains("\\u{1}"), "{escaped}");

        let micros = cell(
            "us",
            DataType::Timestamp(TimeUnit::Microsecond, None),
            Arc::new(arrow_array::TimestampMicrosecondArray::from(vec![Some(1_500)])),
        );
        assert!(micros.text.as_deref().unwrap().contains('.'), "{micros:?}");

        let negative = Decimal256Array::from(vec![Some(i256::from(-1250))])
            .with_precision_and_scale(10, 2)
            .unwrap();
        assert_eq!(
            cell("dec", DataType::Decimal256(10, 2), Arc::new(negative)).text.as_deref(),
            Some("-12.50")
        );
        let whole = Decimal256Array::from(vec![Some(i256::from(-12))])
            .with_precision_and_scale(10, 0)
            .unwrap();
        assert_eq!(
            cell("dec", DataType::Decimal256(10, 0), Arc::new(whole)).text.as_deref(),
            Some("-12")
        );
        let tiny = Decimal256Array::from(vec![Some(i256::from(-1))])
            .with_precision_and_scale(10, 4)
            .unwrap();
        assert_eq!(
            cell("dec", DataType::Decimal256(10, 4), Arc::new(tiny)).text.as_deref(),
            Some("-0.0001")
        );

        let dirty = vec![0x01u8, b'A'];
        let binary = cell("bin", DataType::Binary, Arc::new(BinaryArray::from(vec![Some(dirty.as_slice())])));
        assert!(binary.text.as_deref().unwrap().starts_with("0x"), "{binary:?}");
        let long = vec![0xabu8; 70];
        let long = cell("bin", DataType::Binary, Arc::new(BinaryArray::from(vec![Some(long.as_slice())])));
        assert!(long.truncated, "{long:?}");
        assert!(long.text.as_deref().unwrap().ends_with('…'), "{long:?}");

        use arrow_array::builder::{ListBuilder, StringBuilder};
        let mut lists = ListBuilder::new(StringBuilder::new());
        lists.values().append_value("a\"b");
        lists.values().append_value("c\\d");
        for _ in 0..6 {
            lists.values().append_value("z".repeat(80));
        }
        lists.append(true);
        let list = lists.finish();
        let quoted = cell(
            "xs",
            DataType::List(Arc::new(Field::new("item", DataType::Utf8, true))),
            Arc::new(list),
        );
        let quoted_text = quoted.text.as_deref().unwrap();
        assert!(quoted_text.contains("\\\"") && quoted_text.contains("\\\\"), "{quoted:?}");
        assert!(quoted.truncated, "{quoted:?}");

        let wide = StructArray::from(vec![
            (
                Arc::new(Field::new("a", DataType::Utf8, true)) as _,
                Arc::new(StringArray::from(vec![Some("y".repeat(2_500))])) as ArrayRef,
            ),
            (
                Arc::new(Field::new("b", DataType::Int32, true)) as _,
                Arc::new(Int32Array::from(vec![Some(7)])) as ArrayRef,
            ),
        ]);
        let wide_field = Field::new("row", wide.data_type().clone(), true);
        let wide_cell = format_cell(&wide_field, &(Arc::new(wide) as ArrayRef), 0);
        assert!(wide_cell.truncated, "{wide_cell:?}");
        assert!(wide_cell.title.as_deref().unwrap().ends_with('…'), "{wide_cell:?}");

        let mut values: ArrayRef = Arc::new(Int32Array::from(vec![Some(1)]));
        for _ in 0..8 {
            let field = Arc::new(Field::new("item", values.data_type().clone(), true));
            let offsets = arrow_buffer::OffsetBuffer::new(vec![0, values.len() as i32].into());
            values = Arc::new(arrow_array::ListArray::new(field, offsets, values, None));
        }
        let deep_field = Field::new("deep", values.data_type().clone(), true);
        let deep = format_cell(&deep_field, &values, 0);
        assert!(deep.text.as_deref().unwrap().contains('…'), "{deep:?}");
        assert!(deep.title.is_none(), "{deep:?}");
    }
}

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

//! Deterministic detection of values stored as strings.
//!
//! A column is treated as a detected type when at least 95% of its non-null,
//! non-empty values parse as that type. Ties prefer the more specific type:
//! UUID, timestamp, date, decimal (when any value has a fraction), integer,
//! then boolean. `0`/`1` therefore stay integers. `true`/`false` become
//! booleans because they are not integers.

const PARSE_THRESHOLD: f64 = 0.95;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DetectedKind {
    Integer,
    Decimal,
    Boolean,
    Date,
    Timestamp,
    Uuid,
}

impl DetectedKind {
    pub fn label(self) -> &'static str {
        match self {
            Self::Integer => "int",
            Self::Decimal => "decimal",
            Self::Boolean => "bool",
            Self::Date => "date",
            Self::Timestamp => "timestamp",
            Self::Uuid => "uuid",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Detection {
    pub kind: DetectedKind,
    pub parsed: u64,
    pub unparsed: u64,
    /// Parsed share of non-null, non-empty values, in percent.
    pub parsed_percent: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ParsedNumber {
    Integer(i128),
    Decimal(f64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CivilTime {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
    pub has_time: bool,
}

#[derive(Debug, Default, Clone)]
pub struct StringProbe {
    pub non_empty: u64,
    pub integer: u64,
    pub decimal: u64,
    pub decimal_fraction: bool,
    pub boolean: u64,
    pub date: u64,
    pub timestamp: u64,
    pub uuid: u64,
}

impl StringProbe {
    pub fn observe(&mut self, raw: &str) {
        let text = raw.trim();
        if text.is_empty() {
            return;
        }
        self.non_empty += 1;
        match parse_number(text) {
            Some(ParsedNumber::Integer(_)) => {
                self.integer += 1;
                self.decimal += 1;
            }
            Some(ParsedNumber::Decimal(_)) => {
                self.decimal += 1;
                self.decimal_fraction = true;
            }
            None => {}
        }
        if parse_bool(text).is_some() {
            self.boolean += 1;
        }
        match parse_temporal(text) {
            Some(time) if time.has_time => self.timestamp += 1,
            Some(_) => self.date += 1,
            None => {}
        }
        if parse_uuid(text) {
            self.uuid += 1;
        }
    }

    pub fn detection(&self) -> Option<Detection> {
        if self.non_empty == 0 {
            return None;
        }
        let mut best: Option<(DetectedKind, u64)> = None;
        let mut consider = |kind: DetectedKind, parsed: u64| {
            if !meets(parsed, self.non_empty) {
                return;
            }
            let replace = match best {
                None => true,
                Some((current, current_parsed)) => {
                    prefer(kind, parsed, current, current_parsed, self.decimal_fraction)
                }
            };
            if replace {
                best = Some((kind, parsed));
            }
        };
        consider(DetectedKind::Uuid, self.uuid);
        consider(DetectedKind::Timestamp, self.timestamp);
        consider(DetectedKind::Date, self.date);
        consider(DetectedKind::Decimal, self.decimal);
        consider(DetectedKind::Integer, self.integer);
        consider(DetectedKind::Boolean, self.boolean);
        let (kind, parsed) = best?;
        if kind == DetectedKind::Decimal && !self.decimal_fraction && self.integer == self.decimal {
            // Whole numbers are integers. Decimal stays only when a fraction was seen
            // or integer itself missed the threshold (handled by prefer).
            if meets(self.integer, self.non_empty) {
                return Some(finish(DetectedKind::Integer, self.integer, self.non_empty));
            }
        }
        Some(finish(kind, parsed, self.non_empty))
    }
}

fn finish(kind: DetectedKind, parsed: u64, non_empty: u64) -> Detection {
    Detection {
        kind,
        parsed,
        unparsed: non_empty.saturating_sub(parsed),
        parsed_percent: (parsed as f64) * 100.0 / (non_empty as f64),
    }
}

fn meets(parsed: u64, non_empty: u64) -> bool {
    non_empty > 0 && (parsed as f64) / (non_empty as f64) >= PARSE_THRESHOLD - f64::EPSILON
}

/// `true` when `candidate` should replace `current`.
fn prefer(
    candidate: DetectedKind,
    candidate_parsed: u64,
    current: DetectedKind,
    current_parsed: u64,
    decimal_fraction: bool,
) -> bool {
    if candidate == DetectedKind::Decimal && current == DetectedKind::Integer {
        return decimal_fraction;
    }
    if candidate == DetectedKind::Integer && current == DetectedKind::Decimal {
        return !decimal_fraction || candidate_parsed > current_parsed;
    }
    if candidate == DetectedKind::Boolean && current == DetectedKind::Integer {
        return false;
    }
    rank(candidate) < rank(current)
}

fn rank(kind: DetectedKind) -> u8 {
    match kind {
        DetectedKind::Uuid => 0,
        DetectedKind::Timestamp => 1,
        DetectedKind::Date => 2,
        DetectedKind::Decimal => 3,
        DetectedKind::Integer => 4,
        DetectedKind::Boolean => 5,
    }
}

pub fn parse_number(raw: &str) -> Option<ParsedNumber> {
    let text = raw.trim();
    if text.is_empty() || text.contains(['e', 'E']) {
        return None;
    }
    let (negative, rest) = match text.as_bytes().first() {
        Some(b'+') => (false, &text[1..]),
        Some(b'-') => (true, &text[1..]),
        _ => (false, text),
    };
    if rest.is_empty() || !rest.bytes().any(|byte| byte.is_ascii_digit()) {
        return None;
    }
    if rest.contains('.') && rest.contains(',') {
        return parse_mixed_separators(negative, rest);
    }
    if rest.contains('.') || rest.contains(',') {
        return parse_one_separator(negative, rest);
    }
    if rest.bytes().all(|byte| byte.is_ascii_digit()) {
        return parse_integer_digits(negative, rest).map(ParsedNumber::Integer);
    }
    None
}

fn parse_mixed_separators(negative: bool, rest: &str) -> Option<ParsedNumber> {
    let decimal_at = rest.rfind(['.', ','])?;
    let decimal_sep = rest.as_bytes()[decimal_at] as char;
    let thousands = if decimal_sep == '.' { ',' } else { '.' };
    let int_part = &rest[..decimal_at];
    let frac = &rest[decimal_at + 1..];
    if frac.is_empty() || !frac.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let digits = strip_thousands(int_part, thousands)?;
    Some(decimal_number(negative, &digits, frac))
}

fn parse_one_separator(negative: bool, rest: &str) -> Option<ParsedNumber> {
    let sep = if rest.contains('.') { '.' } else { ',' };
    let parts: Vec<&str> = rest.split(sep).collect();
    if parts.len() < 2 || parts.iter().any(|part| part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit())) {
        return None;
    }
    if parts.len() >= 3 && parts.iter().skip(1).all(|part| part.len() == 3) && parts[0].len() <= 3 {
        let digits: String = parts.concat();
        return parse_integer_digits(negative, &digits).map(ParsedNumber::Integer);
    }
    if parts.len() == 2 {
        // A single separator is a decimal point. `1.234` is 1.234, not 1234.
        // Thousands need at least two separators (`1.234.567`).
        return Some(decimal_number(negative, parts[0], parts[1]));
    }
    None
}

fn strip_thousands(text: &str, sep: char) -> Option<String> {
    if text.is_empty() {
        return Some(String::new());
    }
    let parts: Vec<&str> = text.split(sep).collect();
    if parts.iter().any(|part| part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit())) {
        return None;
    }
    if parts.len() >= 2 {
        if parts[0].len() > 3 || parts.iter().skip(1).any(|part| part.len() != 3) {
            return None;
        }
    }
    Some(parts.concat())
}

fn parse_integer_digits(negative: bool, digits: &str) -> Option<i128> {
    if digits.is_empty() || digits.len() > 38 || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let mut value: i128 = 0;
    for byte in digits.bytes() {
        value = value.checked_mul(10)?.checked_add(i128::from(byte - b'0'))?;
    }
    if negative {
        value = value.checked_neg()?;
    }
    Some(value)
}

fn decimal_number(negative: bool, digits: &str, frac: &str) -> ParsedNumber {
    let mut combined = String::new();
    if negative {
        combined.push('-');
    }
    if digits.is_empty() {
        combined.push('0');
    } else {
        combined.push_str(digits);
    }
    combined.push('.');
    combined.push_str(frac);
    let value = combined.parse::<f64>().unwrap_or(f64::NAN);
    ParsedNumber::Decimal(value)
}

pub fn parse_bool(raw: &str) -> Option<bool> {
    match raw.trim().to_ascii_lowercase().as_str() {
        "true" | "yes" => Some(true),
        "false" | "no" => Some(false),
        "1" => Some(true),
        "0" => Some(false),
        _ => None,
    }
}

pub fn parse_uuid(raw: &str) -> bool {
    let text = raw.trim().as_bytes();
    if text.len() != 36 {
        return false;
    }
    for (index, byte) in text.iter().enumerate() {
        if matches!(index, 8 | 13 | 18 | 23) {
            if *byte != b'-' {
                return false;
            }
        } else if !byte.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

pub fn parse_temporal(raw: &str) -> Option<CivilTime> {
    let text = raw.trim().trim_end_matches('.');
    if text.is_empty() {
        return None;
    }
    let (date, time) = split_date_time(text);
    let (year, month, day) = parse_date(date)?;
    if !is_valid_date(year, month, day) {
        return None;
    }
    let (hour, minute, second) = match time {
        Some(time) => parse_clock(time)?,
        None => (0, 0, 0),
    };
    Some(CivilTime {
        year,
        month,
        day,
        hour,
        minute,
        second,
        has_time: time.is_some(),
    })
}

fn split_date_time(text: &str) -> (&str, Option<&str>) {
    if let Some((date, time)) = text.split_once(['T', 't', ' ']) {
        (date, Some(time))
    } else {
        (text, None)
    }
}

fn parse_date(text: &str) -> Option<(i32, u32, u32)> {
    let text = text.trim_end_matches('.');
    if let Some((y, m, d)) = split3(text, '-') {
        if y.len() == 4 {
            return Some((parse_u32(y)? as i32, parse_u32(m)?, parse_u32(d)?));
        }
    }
    if let Some((a, b, c)) = split3(text, '.') {
        if a.len() == 4 {
            return Some((parse_u32(a)? as i32, parse_u32(b)?, parse_u32(c)?));
        }
        if c.len() == 4 {
            return Some((parse_u32(c)? as i32, parse_u32(b)?, parse_u32(a)?));
        }
    }
    if let Some((m, d, y)) = split3(text, '/') {
        if y.len() == 4 {
            return Some((parse_u32(y)? as i32, parse_u32(m)?, parse_u32(d)?));
        }
    }
    None
}

fn split3(text: &str, sep: char) -> Option<(&str, &str, &str)> {
    let mut parts = text.split(sep);
    let a = parts.next()?;
    let b = parts.next()?;
    let c = parts.next()?;
    if parts.next().is_some() {
        return None;
    }
    Some((a, b, c))
}

fn parse_u32(text: &str) -> Option<u32> {
    if text.is_empty() || text.len() > 4 || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

fn parse_clock(text: &str) -> Option<(u32, u32, u32)> {
    let text = text.trim();
    let text = text.split_once(['Z', 'z']).map(|(head, _)| head).unwrap_or(text);
    let text = strip_offset(text)?;
    let text = text.split_once('.').map(|(head, _)| head).unwrap_or(text);
    let mut parts = text.split(':');
    let hour = parse_u32(parts.next()?)?;
    let minute = parse_u32(parts.next()?)?;
    let second = match parts.next() {
        Some(value) => parse_u32(value)?,
        None => 0,
    };
    if parts.next().is_some() || hour > 23 || minute > 59 || second > 60 {
        return None;
    }
    Some((hour, minute, second))
}

fn strip_offset(text: &str) -> Option<&str> {
    if let Some(index) = text.rfind(['+', '-']) {
        if index > 0 {
            let offset = &text[index + 1..];
            let ok = match offset.len() {
                4 | 5 if offset.as_bytes().iter().filter(|byte| byte.is_ascii_digit()).count() >= 3 => true,
                _ => false,
            };
            if ok {
                return Some(&text[..index]);
            }
        }
    }
    Some(text)
}

fn is_valid_date(year: i32, month: u32, day: u32) -> bool {
    if !(1..=12).contains(&month) || day == 0 || year < -9999 || year > 9999 {
        return false;
    }
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let max_day = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => 0,
    };
    day <= max_day
}

pub fn format_civil(time: CivilTime) -> String {
    if time.has_time {
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            time.year, time.month, time.day, time.hour, time.minute, time.second
        )
    } else {
        format!("{:04}-{:02}-{:02}", time.year, time.month, time.day)
    }
}

/// Sample standard deviation from Welford's M2. Zero when fewer than two values.
pub fn sample_stddev(count: u64, m2: f64) -> f64 {
    if count < 2 {
        0.0
    } else {
        (m2 / (count - 1) as f64).sqrt()
    }
}

/// Linear percentile on a sorted slice. `p` is 0..=1. Rank is `p * (n - 1)`.
pub fn percentile(sorted: &[f64], p: f64) -> Option<f64> {
    if sorted.is_empty() || !(0.0..=1.0).contains(&p) {
        return None;
    }
    if sorted.len() == 1 {
        return Some(sorted[0]);
    }
    let rank = p * (sorted.len() - 1) as f64;
    let low = rank.floor() as usize;
    let high = rank.ceil() as usize;
    let fraction = rank - low as f64;
    Some(sorted[low] * (1.0 - fraction) + sorted[high] * fraction)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detect(values: &[&str]) -> Option<Detection> {
        let mut probe = StringProbe::default();
        for value in values {
            probe.observe(value);
        }
        probe.detection()
    }

    #[test]
    fn integers_and_the_threshold() {
        let mut values = vec!["10"; 95];
        values.extend(std::iter::repeat_n("nope", 5));
        let found = detect(&values).unwrap();
        assert_eq!(found.kind, DetectedKind::Integer);
        assert!((found.parsed_percent - 95.0).abs() < 0.01);

        let mut below = vec!["10"; 94];
        below.extend(std::iter::repeat_n("nope", 6));
        assert!(detect(&below).is_none());
    }

    #[test]
    fn zero_and_one_stay_integers_words_are_bools() {
        assert_eq!(detect(&["0", "1", "0", "1"]).unwrap().kind, DetectedKind::Integer);
        assert_eq!(detect(&["true", "false", "yes", "NO"]).unwrap().kind, DetectedKind::Boolean);
    }

    #[test]
    fn decimal_separators_and_thousands() {
        assert_eq!(parse_number("1.50"), Some(ParsedNumber::Decimal(1.50)));
        assert_eq!(parse_number("1,50"), Some(ParsedNumber::Decimal(1.50)));
        assert_eq!(parse_number("-1.234"), Some(ParsedNumber::Decimal(-1.234)));
        assert_eq!(parse_number("1.234.567"), Some(ParsedNumber::Integer(1_234_567)));
        assert_eq!(parse_number("1,234,567"), Some(ParsedNumber::Integer(1_234_567)));
        assert_eq!(parse_number("1,234.50"), Some(ParsedNumber::Decimal(1234.50)));
        assert_eq!(parse_number("1.234,50"), Some(ParsedNumber::Decimal(1234.50)));
        assert!(parse_number("1,234,56").is_none());
        assert_eq!(detect(&["1,50", "2.25", "3"]).unwrap().kind, DetectedKind::Decimal);
        assert_eq!(detect(&["1.234.567", "2"]).unwrap().kind, DetectedKind::Integer);
    }

    #[test]
    fn dates_timestamps_and_uuids() {
        assert_eq!(
            parse_temporal("2020-01-02").unwrap(),
            CivilTime { year: 2020, month: 1, day: 2, hour: 0, minute: 0, second: 0, has_time: false }
        );
        let dotted = parse_temporal("02.01.2020").unwrap();
        assert_eq!((dotted.year, dotted.month, dotted.day), (2020, 1, 2));
        let hungarian = parse_temporal("2020.01.02.").unwrap();
        assert_eq!((hungarian.year, hungarian.month, hungarian.day, hungarian.has_time), (2020, 1, 2, false));
        let us = parse_temporal("01/02/2020 03:04").unwrap();
        assert!(us.has_time);
        assert_eq!((us.month, us.day, us.hour, us.minute), (1, 2, 3, 4));
        assert!(parse_temporal("2020-01-02T03:04:05Z").unwrap().has_time);
        assert!(parse_temporal("2020-02-31").is_none());
        assert!(parse_temporal("13/02/2020").is_none());
        assert_eq!(detect(&["2020-01-02", "03.04.2021"]).unwrap().kind, DetectedKind::Date);
        assert_eq!(detect(&["2020-01-02T00:00:00Z"]).unwrap().kind, DetectedKind::Timestamp);
        let uuid = "550e8400-e29b-41d4-a716-446655440000";
        assert!(parse_uuid(uuid));
        assert_eq!(detect(&[uuid, &uuid.to_ascii_uppercase()]).unwrap().kind, DetectedKind::Uuid);
        assert!(!parse_uuid("not-a-uuid"));
    }

    #[test]
    fn every_kind_has_a_label_and_bad_clocks_are_rejected() {
        assert_eq!(DetectedKind::Integer.label(), "int");
        assert_eq!(DetectedKind::Decimal.label(), "decimal");
        assert_eq!(DetectedKind::Boolean.label(), "bool");
        assert_eq!(DetectedKind::Date.label(), "date");
        assert_eq!(DetectedKind::Timestamp.label(), "timestamp");
        assert_eq!(DetectedKind::Uuid.label(), "uuid");
        assert!(parse_temporal("2020-01-02T24:00:00Z").is_none());
        assert!(parse_temporal("2020-01-02T12:60:00Z").is_none());
        assert!(parse_temporal("2020-01-02T12:00:61Z").is_none());
        assert!(parse_number("").is_none());
        assert!(parse_number("1e2").is_none());
        assert!(parse_number("+").is_none());
        assert!(parse_number("1.2.3.4").is_none());
        assert!((sample_stddev(4, 4.0) - (4.0 / 3.0_f64).sqrt()).abs() < 1e-9);
        assert_eq!(percentile(&[], 0.5), None);
        assert_eq!(percentile(&[2.0], 0.0), Some(2.0));
        assert_eq!(format_civil(CivilTime {
            year: 2020,
            month: 1,
            day: 2,
            hour: 3,
            minute: 4,
            second: 5,
            has_time: true,
        }), "2020-01-02T03:04:05Z");
    }

    #[test]
    fn blanks_do_not_count_and_percentiles_are_linear() {
        let mut probe = StringProbe::default();
        probe.observe("  ");
        probe.observe("");
        for _ in 0..18 {
            probe.observe("4");
        }
        probe.observe("nope");
        probe.observe("nope");
        assert!(probe.detection().is_none());
        let sorted = [1.0, 2.0, 3.0, 4.0];
        assert_eq!(percentile(&sorted, 0.25), Some(1.75));
        assert_eq!(percentile(&sorted, 0.5), Some(2.5));
        assert_eq!(percentile(&sorted, 0.75), Some(3.25));
        assert_eq!(sample_stddev(1, 0.0), 0.0);
    }
}

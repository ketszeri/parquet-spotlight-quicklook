/// Hard ceilings. Callers can ask for less, never more.
/// 1000 rows is the ceiling the preview UI can offer. The 2 s and 32 MiB caps
/// still stop a read early; this is not a license to scan a whole file.
pub const HARD_MAX_ROWS: u32 = 1000;
pub const HARD_MAX_COLUMNS: u32 = 50;
pub const HARD_MAX_BYTES: u64 = 32 * 1024 * 1024;
pub const HARD_MAX_MILLIS: u32 = 2_000;
pub const HARD_MAX_UNCOMPRESSED: u64 = 64 * 1024 * 1024;
pub const HARD_MAX_PAGE_UNCOMPRESSED: u64 = 8 * 1024 * 1024;

pub const DEFAULT_MAX_ROWS: u32 = 100;
pub const DEFAULT_MAX_COLUMNS: u32 = 50;
pub const DEFAULT_MAX_BYTES: u64 = HARD_MAX_BYTES;
pub const DEFAULT_MAX_MILLIS: u32 = HARD_MAX_MILLIS;

pub const DISPLAY_CHARS: usize = 80;
pub const TITLE_CHARS: usize = 2_000;
pub const MAX_NESTED_ITEMS: usize = 8;
pub const TITLE_NESTED_ITEMS: usize = 32;

#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub max_rows: u32,
    pub max_columns: u32,
    pub max_bytes: u64,
    pub max_millis: u32,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_rows: DEFAULT_MAX_ROWS,
            max_columns: DEFAULT_MAX_COLUMNS,
            max_bytes: DEFAULT_MAX_BYTES,
            max_millis: DEFAULT_MAX_MILLIS,
        }
    }
}

impl Limits {
    /// Clamp caller-supplied limits to the hard ceilings.
    ///
    /// `max_millis == 0` is preserved so tests can force an immediate timeout.
    /// `max_bytes` keeps small values so the byte cap can be tested.
    pub fn sanitized(self) -> Self {
        Self {
            max_rows: self.max_rows.clamp(1, HARD_MAX_ROWS),
            max_columns: self.max_columns.clamp(1, HARD_MAX_COLUMNS),
            max_bytes: self.max_bytes.min(HARD_MAX_BYTES).max(1),
            max_millis: self.max_millis.min(HARD_MAX_MILLIS),
        }
    }
}

//! Bounded Parquet row preview used by the Quick Look extension.
//!
//! The Spotlight importer does not link this crate. Quick Look calls
//! [`parquet_preview_read`] and falls back to the schema view on any error.

mod budget;
mod capped;
mod decode;
mod detect;
mod error;
mod format;
mod limits;
mod preflight;
mod stats;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

pub use decode::{Preview, PreviewCell, PreviewColumn};
pub use error::PreviewError;
pub use limits::Limits;
pub use stats::{stats_path, FileStats, StatsLimits};

/// Read up to `limits` rows. Returns a short [`PreviewError`] instead of panicking.
pub fn preview_path(path: &Path, limits: Limits) -> Result<Preview, PreviewError> {
    let limits = limits.sanitized();
    if limits.max_millis == 0 {
        return Err(PreviewError::Timeout);
    }
    let path = path.to_path_buf();
    let (tx, rx) = mpsc::channel();
    let cancel = Arc::new(AtomicBool::new(false));
    let cancel_worker = Arc::clone(&cancel);
    thread::spawn(move || {
        let result = catch_unwind(AssertUnwindSafe(|| {
            decode::decode_file(&path, limits, cancel_worker)
        }));
        let _ = tx.send(result);
    });
    match rx.recv_timeout(Duration::from_millis(u64::from(limits.max_millis))) {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err(PreviewError::Decode),
        Err(_) => {
            cancel.store(true, Ordering::Relaxed);
            Err(PreviewError::Timeout)
        }
    }
}

/// C ABI limits. A null pointer selects the defaults (100 rows, 50 columns, 32 MiB, 2 s).
#[repr(C)]
pub struct parquet_preview_limits {
    pub max_rows: u32,
    pub max_columns: u32,
    pub max_bytes: u64,
    pub max_millis: u32,
}

/// Decode a Parquet file into a JSON document.
///
/// Returns 0 on success. On failure returns a non-zero code and, when `out_error`
/// is non-null, a short message. The caller frees both strings with
/// [`parquet_preview_string_free`].
///
/// # Safety
/// `path` must be a valid C string for the duration of the call. `limits` is
/// either null or a readable [`parquet_preview_limits`]. `out_json` and
/// `out_error` are either null or writable pointers.
#[no_mangle]
pub unsafe extern "C" fn parquet_preview_read(
    path: *const c_char,
    limits: *const parquet_preview_limits,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if !out_json.is_null() {
        unsafe { *out_json = std::ptr::null_mut() };
    }
    if !out_error.is_null() {
        unsafe { *out_error = std::ptr::null_mut() };
    }
    let failed = |error: PreviewError| -> i32 {
        write_c_string(out_error, error.message());
        1
    };
    if path.is_null() {
        return failed(PreviewError::Io);
    }
    let path = unsafe { CStr::from_ptr(path) };
    let path = match path.to_str() {
        Ok(path) => path,
        Err(_) => return failed(PreviewError::Io),
    };
    let limits = if limits.is_null() {
        Limits::default()
    } else {
        let limits = unsafe { &*limits };
        Limits {
            max_rows: limits.max_rows,
            max_columns: limits.max_columns,
            max_bytes: limits.max_bytes,
            max_millis: limits.max_millis,
        }
    };
    match preview_path(Path::new(path), limits) {
        Ok(preview) => match preview.to_json() {
            Ok(json) => {
                if write_c_string(out_json, &json) {
                    0
                } else {
                    failed(PreviewError::MemoryLimit)
                }
            }
            Err(error) => failed(error),
        },
        Err(error) => failed(error),
    }
}

/// Column statistics limits. A null pointer selects the defaults.
#[repr(C)]
pub struct parquet_preview_stats_limits {
    pub max_columns: u32,
    pub max_bytes: u64,
    pub max_millis: u32,
}

/// Stream column statistics for `path`.
///
/// `cancel` may be null. When non-null, a non-zero value stops the scan and
/// the returned JSON is marked partial if any rows were read.
///
/// # Safety
/// `path` must be a valid C string. `limits` is null or readable.
/// `cancel` is null or points at an `i32` that stays alive for the call.
/// `out_json` and `out_error` are null or writable.
#[no_mangle]
pub unsafe extern "C" fn parquet_preview_stats(
    path: *const c_char,
    limits: *const parquet_preview_stats_limits,
    cancel: *mut i32,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if !out_json.is_null() {
        unsafe { *out_json = std::ptr::null_mut() };
    }
    if !out_error.is_null() {
        unsafe { *out_error = std::ptr::null_mut() };
    }
    let failed = |error: PreviewError| -> i32 {
        write_c_string(out_error, error.message());
        1
    };
    if path.is_null() {
        return failed(PreviewError::Io);
    }
    let path = unsafe { CStr::from_ptr(path) };
    let path = match path.to_str() {
        Ok(path) => path,
        Err(_) => return failed(PreviewError::Io),
    };
    let limits = if limits.is_null() {
        StatsLimits::default()
    } else {
        let limits = unsafe { &*limits };
        StatsLimits {
            max_columns: limits.max_columns,
            max_bytes: limits.max_bytes,
            max_millis: limits.max_millis,
        }
    };
    let backstop = Duration::from_millis(u64::from(limits.sanitized().max_millis.saturating_add(1_000)));
    let flag = Arc::new(AtomicBool::new(false));
    let flag_worker = Arc::clone(&flag);
    let path = Path::new(path).to_path_buf();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let result = catch_unwind(AssertUnwindSafe(|| stats::stats_path(&path, limits, flag_worker)));
        let _ = tx.send(result);
    });
    let started = Instant::now();
    loop {
        if !cancel.is_null() && unsafe { std::ptr::read_volatile(cancel) } != 0 {
            flag.store(true, Ordering::Relaxed);
        }
        match rx.recv_timeout(Duration::from_millis(40)) {
            Ok(Ok(Ok(stats))) => {
                return match stats.to_json() {
                    Ok(json) => {
                        if write_c_string(out_json, &json) {
                            0
                        } else {
                            failed(PreviewError::MemoryLimit)
                        }
                    }
                    Err(error) => failed(error),
                };
            }
            Ok(Ok(Err(error))) => return failed(error),
            Ok(Err(_)) => return failed(PreviewError::Decode),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if started.elapsed() > backstop {
                    flag.store(true, Ordering::Relaxed);
                    return failed(PreviewError::Timeout);
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => return failed(PreviewError::Decode),
        }
    }
}

/// Release a string returned by [`parquet_preview_read`].
///
/// # Safety
/// `ptr` must be null or a pointer previously returned by this library.
#[no_mangle]
pub unsafe extern "C" fn parquet_preview_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    unsafe { drop(CString::from_raw(ptr)) };
}

fn write_c_string(slot: *mut *mut c_char, text: &str) -> bool {
    if slot.is_null() {
        return false;
    }
    match CString::new(text) {
        Ok(value) => {
            unsafe { *slot = value.into_raw() };
            true
        }
        Err(_) => false,
    }
}

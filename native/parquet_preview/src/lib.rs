//! Bounded Parquet row preview used by the Quick Look extension.
//!
//! The Spotlight importer does not link this crate. Quick Look calls
//! [`parquet_preview_read`] and falls back to the schema view on any error.

mod budget;
mod capped;
mod decode;
mod detect;
mod error;
mod export;
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

/// Excel plan. Field order matches `parquet_preview_export_plan` in the C header.
#[repr(C)]
pub struct parquet_preview_export_plan {
    pub rows: i64,
    pub columns: u32,
    pub sheets: u32,
    pub truncated_columns: u32,
}

fn fill_plan(slot: *mut parquet_preview_export_plan, plan: &export::ExportPlan) {
    if slot.is_null() {
        return;
    }
    unsafe {
        *slot = parquet_preview_export_plan {
            rows: plan.rows,
            columns: u32::try_from(plan.columns).unwrap_or(u32::MAX),
            sheets: plan.sheets,
            truncated_columns: u32::try_from(plan.truncated_columns).unwrap_or(u32::MAX),
        };
    }
}

fn export_failed(out_error: *mut *mut c_char, error: export::ExportError) -> i32 {
    write_c_string(out_error, error.message());
    1
}

unsafe fn c_text<'a>(ptr: *const c_char) -> Result<&'a str, export::ExportError> {
    if ptr.is_null() {
        return Err(export::ExportError::Message("could not read the file"));
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map_err(|_| export::ExportError::Message("could not read the file"))
}

/// Read the footer and report how an Excel export would be split.
///
/// # Safety
/// `path` must be a valid C string. `out_plan` must be writable. `out_error`
/// is null or writable.
#[no_mangle]
pub unsafe extern "C" fn parquet_preview_plan(
    path: *const c_char,
    out_plan: *mut parquet_preview_export_plan,
    out_error: *mut *mut c_char,
) -> i32 {
    if !out_error.is_null() {
        unsafe { *out_error = std::ptr::null_mut() };
    }
    if out_plan.is_null() {
        return export_failed(out_error, export::ExportError::Message("export could not read the file"));
    }
    let path = match unsafe { c_text(path) } {
        Ok(path) => path,
        Err(error) => return export_failed(out_error, error),
    };
    let result = catch_unwind(AssertUnwindSafe(|| export::plan_path(Path::new(path))));
    match result {
        Ok(Ok(plan)) => {
            fill_plan(out_plan, &plan);
            0
        }
        Ok(Err(error)) => export_failed(out_error, error),
        Err(_) => export_failed(out_error, export::ExportError::Message("export could not read the file")),
    }
}

/// Stream `source` into an `.xlsx` at `dest`.
///
/// `progress` may be null. A non-zero `cancel` stops the write between rows.
/// The call blocks the caller; Swift must leave the main thread.
///
/// # Safety
/// `source` and `dest` must be valid C strings. `progress` is null or points
/// at an [`export::ExportProgress`] that stays alive for the call. `out_error`
/// is null or writable.
#[no_mangle]
pub unsafe extern "C" fn parquet_preview_export_file(
    source: *const c_char,
    dest: *const c_char,
    progress: *mut export::ExportProgress,
    out_error: *mut *mut c_char,
) -> i32 {
    if !out_error.is_null() {
        unsafe { *out_error = std::ptr::null_mut() };
    }
    let source = match unsafe { c_text(source) } {
        Ok(path) => path,
        Err(error) => return export_failed(out_error, error),
    };
    let dest = match unsafe { c_text(dest) } {
        Ok(path) => path,
        Err(error) => return export_failed(out_error, error),
    };
    let source = Path::new(source).to_path_buf();
    let dest = Path::new(dest).to_path_buf();
    let result = catch_unwind(AssertUnwindSafe(|| export::export_file(&source, &dest, progress)));
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => export_failed(out_error, error),
        Err(_) => export_failed(out_error, export::ExportError::Message("export could not save the workbook")),
    }
}

/// Write the already loaded rows view. `json` is `{"columns":[{"name","type"}],"rows":[...]}`.
///
/// # Safety
/// `json` and `dest` must be valid C strings. `out_plan` may be null. `out_error`
/// is null or writable.
#[no_mangle]
pub unsafe extern "C" fn parquet_preview_export_table(
    json: *const c_char,
    dest: *const c_char,
    out_plan: *mut parquet_preview_export_plan,
    out_error: *mut *mut c_char,
) -> i32 {
    if !out_error.is_null() {
        unsafe { *out_error = std::ptr::null_mut() };
    }
    let json = match unsafe { c_text(json) } {
        Ok(json) => json,
        Err(error) => return export_failed(out_error, error),
    };
    let dest = match unsafe { c_text(dest) } {
        Ok(path) => path,
        Err(error) => return export_failed(out_error, error),
    };
    let json = json.to_string();
    let dest = Path::new(dest).to_path_buf();
    let result = catch_unwind(AssertUnwindSafe(|| export::export_table(&json, &dest)));
    match result {
        Ok(Ok(plan)) => {
            fill_plan(out_plan, &plan);
            0
        }
        Ok(Err(error)) => export_failed(out_error, error),
        Err(_) => export_failed(out_error, export::ExportError::Message("export could not save the workbook")),
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

#[cfg(test)]
mod export_abi_tests {
    use super::*;
    use std::ffi::CString;
    use std::io::Read;

    #[test]
    fn plan_and_file_round_trip_through_the_c_abi() {
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/parquet/snappy.parquet");
        let dir = std::env::temp_dir().join(format!("parquet-xlsx-abi-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let dest = dir.join("abi.xlsx");
        let source_c = CString::new(source.to_str().unwrap()).unwrap();
        let dest_c = CString::new(dest.to_str().unwrap()).unwrap();
        let mut plan = parquet_preview_export_plan {
            rows: 0,
            columns: 0,
            sheets: 0,
            truncated_columns: 0,
        };
        let mut error = std::ptr::null_mut();
        let rc = unsafe { parquet_preview_plan(source_c.as_ptr(), &mut plan, &mut error) };
        assert_eq!(rc, 0, "{}", unsafe { error_text(error) });
        assert_eq!(plan.rows, 3);
        assert!(plan.sheets >= 1);
        unsafe { parquet_preview_string_free(error) };
        let mut progress = export::ExportProgress {
            rows_written: 0,
            rows_total: 0,
            cancel: 0,
        };
        error = std::ptr::null_mut();
        let rc = unsafe {
            parquet_preview_export_file(source_c.as_ptr(), dest_c.as_ptr(), &mut progress, &mut error)
        };
        assert_eq!(rc, 0, "{}", unsafe { error_text(error) });
        assert_eq!(progress.rows_written, 3);
        let file = std::fs::File::open(&dest).unwrap();
        let mut archive = zip::ZipArchive::new(file).unwrap();
        let mut sheet = String::new();
        archive.by_name("xl/worksheets/sheet1.xml").unwrap().read_to_string(&mut sheet).unwrap();
        assert!(sheet.contains("alpha"), "{sheet}");
        assert!(!sheet.contains("<f>"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_and_stats_round_trip_and_reject_bad_pointers() {
        let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/parquet/snappy.parquet");
        let source_c = CString::new(source.to_str().unwrap()).unwrap();
        let mut json = std::ptr::null_mut();
        let mut error = std::ptr::null_mut();
        let rc = unsafe { parquet_preview_read(source_c.as_ptr(), std::ptr::null(), &mut json, &mut error) };
        assert_eq!(rc, 0, "{}", unsafe { error_text(error) });
        let text = unsafe { CStr::from_ptr(json).to_string_lossy().into_owned() };
        assert!(text.contains("alpha"), "{text}");
        unsafe {
            parquet_preview_string_free(json);
            parquet_preview_string_free(error);
        }

        let limits = parquet_preview_limits {
            max_rows: 10,
            max_columns: 1,
            max_bytes: 1024 * 1024,
            max_millis: 2_000,
        };
        json = std::ptr::null_mut();
        error = std::ptr::null_mut();
        let rc = unsafe { parquet_preview_read(source_c.as_ptr(), &limits, &mut json, &mut error) };
        assert_eq!(rc, 0, "{}", unsafe { error_text(error) });
        unsafe { parquet_preview_string_free(json) };

        error = std::ptr::null_mut();
        let rc = unsafe { parquet_preview_read(std::ptr::null(), std::ptr::null(), &mut json, &mut error) };
        assert_ne!(rc, 0);
        unsafe { parquet_preview_string_free(error) };

        let missing = CString::new(format!("/tmp/parquet-missing-abi-{}", std::process::id())).unwrap();
        error = std::ptr::null_mut();
        let rc = unsafe { parquet_preview_read(missing.as_ptr(), std::ptr::null(), &mut json, &mut error) };
        assert_ne!(rc, 0);
        unsafe { parquet_preview_string_free(error) };

        let bad = unsafe { CString::from_vec_unchecked(vec![0xff]) };
        error = std::ptr::null_mut();
        let rc = unsafe { parquet_preview_read(bad.as_ptr(), std::ptr::null(), &mut json, &mut error) };
        assert_ne!(rc, 0);
        unsafe { parquet_preview_string_free(error) };

        let rc = unsafe {
            parquet_preview_read(source_c.as_ptr(), std::ptr::null(), std::ptr::null_mut(), std::ptr::null_mut())
        };
        assert_ne!(rc, 0);

        json = std::ptr::null_mut();
        error = std::ptr::null_mut();
        let mut cancel = 0i32;
        let stats_limits = parquet_preview_stats_limits {
            max_columns: 8,
            max_bytes: 32 * 1024 * 1024,
            max_millis: 2_000,
        };
        let rc = unsafe {
            parquet_preview_stats(source_c.as_ptr(), &stats_limits, &mut cancel, &mut json, &mut error)
        };
        assert_eq!(rc, 0, "{}", unsafe { error_text(error) });
        let stats = unsafe { CStr::from_ptr(json).to_string_lossy().into_owned() };
        assert!(stats.contains("\"name\":\"id\"") || stats.contains("id"), "{stats}");
        unsafe {
            parquet_preview_string_free(json);
            parquet_preview_string_free(error);
        }

        json = std::ptr::null_mut();
        error = std::ptr::null_mut();
        let rc = unsafe {
            parquet_preview_stats(source_c.as_ptr(), std::ptr::null(), std::ptr::null_mut(), &mut json, &mut error)
        };
        assert_eq!(rc, 0, "{}", unsafe { error_text(error) });
        unsafe { parquet_preview_string_free(json) };

        error = std::ptr::null_mut();
        let rc = unsafe {
            parquet_preview_stats(std::ptr::null(), std::ptr::null(), std::ptr::null_mut(), &mut json, &mut error)
        };
        assert_ne!(rc, 0);
        unsafe { parquet_preview_string_free(error) };

        let mut plan = parquet_preview_export_plan { rows: 0, columns: 0, sheets: 0, truncated_columns: 0 };
        error = std::ptr::null_mut();
        assert_ne!(unsafe { parquet_preview_plan(std::ptr::null(), &mut plan, &mut error) }, 0);
        unsafe { parquet_preview_string_free(error) };
        error = std::ptr::null_mut();
        assert_ne!(unsafe { parquet_preview_plan(source_c.as_ptr(), std::ptr::null_mut(), &mut error) }, 0);
        unsafe { parquet_preview_string_free(error) };
        error = std::ptr::null_mut();
        assert_ne!(
            unsafe { parquet_preview_export_file(std::ptr::null(), std::ptr::null(), std::ptr::null_mut(), &mut error) },
            0
        );
        unsafe { parquet_preview_string_free(error) };
        let table = CString::new(r#"{"columns":[{"name":"n","type":"int64"}],"rows":[["1"]]}"#).unwrap();
        let dest = std::env::temp_dir().join(format!("parquet-abi-table-{}.xlsx", std::process::id()));
        let dest_c = CString::new(dest.to_str().unwrap()).unwrap();
        error = std::ptr::null_mut();
        let rc = unsafe { parquet_preview_export_table(table.as_ptr(), dest_c.as_ptr(), &mut plan, &mut error) };
        assert_eq!(rc, 0, "{}", unsafe { error_text(error) });
        assert_eq!(plan.rows, 1);
        unsafe { parquet_preview_string_free(error) };
        unsafe { parquet_preview_string_free(std::ptr::null_mut()) };
        let _ = std::fs::remove_file(&dest);
    }

    unsafe fn error_text(ptr: *mut c_char) -> String {
        if ptr.is_null() {
            return String::new();
        }
        unsafe { CStr::from_ptr(ptr).to_string_lossy().into_owned() }
    }
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

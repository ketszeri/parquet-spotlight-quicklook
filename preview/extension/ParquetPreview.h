#ifndef PARQUET_PREVIEW_H
#define PARQUET_PREVIEW_H

#include <stdint.h>

/* Field order matches the Rust `parquet_preview_limits` struct. */
typedef struct parquet_preview_limits {
    uint32_t max_rows;
    uint32_t max_columns;
    uint64_t max_bytes;
    uint32_t max_millis;
} parquet_preview_limits;

/* 0 on success. Caller frees both strings with parquet_preview_string_free. */
int32_t parquet_preview_read(
    const char * _Nonnull path,
    const parquet_preview_limits * _Nonnull limits,
    char * _Nullable * _Nonnull out_json,
    char * _Nullable * _Nonnull out_error
);

void parquet_preview_string_free(char * _Nullable ptr);

/* Field order matches the Rust `parquet_preview_stats_limits` struct. */
typedef struct parquet_preview_stats_limits {
    uint32_t max_columns;
    uint64_t max_bytes;
    uint32_t max_millis;
} parquet_preview_stats_limits;

/* Field order matches the Rust `parquet_preview_export_plan` struct. */
typedef struct parquet_preview_export_plan {
    int64_t rows;
    uint32_t columns;
    uint32_t sheets;
    uint32_t truncated_columns;
} parquet_preview_export_plan;

/* Field order matches the Rust `ExportProgress` struct. */
typedef struct parquet_preview_export_progress {
    uint64_t rows_written;
    uint64_t rows_total;
    int32_t cancel;
} parquet_preview_export_progress;

/* 0 on success. Reads the footer only. */
int32_t parquet_preview_plan(
    const char * _Nonnull path,
    parquet_preview_export_plan * _Nonnull out_plan,
    char * _Nullable * _Nonnull out_error
);

/* 0 on success. `progress` may be NULL; a non-zero cancel stops the write. */
int32_t parquet_preview_export_file(
    const char * _Nonnull source,
    const char * _Nonnull dest,
    parquet_preview_export_progress * _Nullable progress,
    char * _Nullable * _Nonnull out_error
);

/* 0 on success. `json` is the rows view already loaded in the preview. */
int32_t parquet_preview_export_table(
    const char * _Nonnull json,
    const char * _Nonnull dest,
    parquet_preview_export_plan * _Nullable out_plan,
    char * _Nullable * _Nonnull out_error
);

/* 0 on success. `cancel` may be NULL; a non-zero value stops the scan. */
int32_t parquet_preview_stats(
    const char * _Nonnull path,
    const parquet_preview_stats_limits * _Nonnull limits,
    int32_t * _Nullable cancel,
    char * _Nullable * _Nonnull out_json,
    char * _Nullable * _Nonnull out_error
);

#if defined(__OBJC__)
#import <Foundation/Foundation.h>
/* Runs block and returns the NSException as an NSError. NS_NOESCAPE so Swift can mutate captures. */
NSError * _Nullable ParquetCatchException(NS_NOESCAPE void (^ _Nonnull block)(void));
/* Test host: call the Quick Look selector Finder uses. Not used by the appex. */
void ParquetHostPrepare(id _Nonnull controller, NSURL * _Nonnull url, void (^ _Nonnull handler)(NSError * _Nullable error));
#endif

#endif

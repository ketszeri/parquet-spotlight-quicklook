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
    const char *path,
    const parquet_preview_limits *limits,
    char **out_json,
    char **out_error
);

void parquet_preview_string_free(char *ptr);

#if defined(__OBJC__)
#import <Foundation/Foundation.h>
/* Runs block and returns the NSException as an NSError. NS_NOESCAPE so Swift can mutate captures. */
NSError * _Nullable ParquetCatchException(NS_NOESCAPE void (^ _Nonnull block)(void));
/* Test host: call the Quick Look selector Finder uses. Not used by the appex. */
void ParquetHostPrepare(id _Nonnull controller, NSURL * _Nonnull url, void (^ _Nonnull handler)(NSError * _Nullable error));
#endif

#endif

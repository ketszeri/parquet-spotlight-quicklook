import Foundation

struct StatsTopValue {
    var value: String
    var count: Int64
}

struct StatsColumn {
    var name: String
    var storageType: String
    var detected: String?
    var parsedPercent: Double?
    var unparsed: Int64
    var count: Int64
    var nulls: Int64
    var nullPercent: Double
    var nullsScope: String
    var distinct: Int64?
    var distinctExact: Bool
    var min: String?
    var max: String?
    var mean: String?
    var median: String?
    var stddev: String?
    var p25: String?
    var p75: String?
    var p95: String?
    var p99: String?
    var minNumber: Double?
    var maxNumber: Double?
    var medianNumber: Double?
    var medianLow: Double?
    var medianHigh: Double?
    var medianLowText: String?
    var medianHighText: String?
    var p95Number: Double?
    var p99Number: Double?
    var minCount: Int64?
    var maxCount: Int64?
    var medianCount: Int64?
    var p95Count: Int64?
    var p99Count: Int64?
    var percentilesExact: Bool
    var temporal: Bool
    var top: [StatsTopValue]
    var values: [StatsTopValue]
    var valuesCapped: Bool

    var marker: ColumnStatsFormat.InferredMarker? {
        ColumnStatsFormat.inferredMarker(storage: storageType, detected: detected, parsedPercent: parsedPercent, unparsed: unparsed)
    }

    var typeLabel: String {
        marker?.label ?? storageType
    }

    var isPartial: Bool {
        marker?.partial == true
    }
}

struct StatsDocument {
    var fileRows: Int64
    var scannedRows: UInt64
    var partial: Bool
    var columns: [StatsColumn]
}

enum StatsDecoder {
    static let maxColumns: UInt32 = 256
    static let maxBytes: UInt64 = 256 * 1024 * 1024
    static let maxMillis: UInt32 = 8_000

    static func read(path: String, cancel: UnsafeMutablePointer<Int32>) -> Result<StatsDocument, String> {
        var limits = parquet_preview_stats_limits(
            max_columns: maxColumns,
            max_bytes: maxBytes,
            max_millis: maxMillis
        )
        return path.withCString { cPath in
            var jsonPtr: UnsafeMutablePointer<CChar>?
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = parquet_preview_stats(cPath, &limits, cancel, &jsonPtr, &errPtr)
            defer {
                if let jsonPtr { parquet_preview_string_free(jsonPtr) }
                if let errPtr { parquet_preview_string_free(errPtr) }
            }
            if rc != 0 {
                let message = errPtr.map { String(cString: $0) } ?? "column stats could not be computed"
                return .failure(String(message.prefix(180)))
            }
            guard let jsonPtr else { return .failure("column stats could not be computed") }
            let json = String(cString: jsonPtr)
            guard json.utf8.count <= 2 * 1024 * 1024,
                  let data = json.data(using: .utf8),
                  let document = parse(data) else {
                return .failure("column stats could not be computed")
            }
            return .success(document)
        }
    }

    static func parse(_ data: Data) -> StatsDocument? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawColumns = obj["columns"] as? [[String: Any]] else {
            return nil
        }
        return StatsDocument(
            fileRows: int64(obj["file_rows"]),
            scannedRows: uint64(obj["scanned_rows"]),
            partial: bool(obj["partial"]),
            columns: rawColumns.map(parseColumn)
        )
    }

    private static func parseColumn(_ raw: [String: Any]) -> StatsColumn {
        var top: [StatsTopValue] = []
        if let rawTop = raw["top"] as? [[String: Any]] {
            for item in rawTop {
                top.append(StatsTopValue(value: item["value"] as? String ?? "", count: int64(item["count"])))
            }
        }
        var values: [StatsTopValue] = []
        if let rawValues = raw["values"] as? [[String: Any]] {
            for item in rawValues {
                values.append(StatsTopValue(value: item["value"] as? String ?? "", count: int64(item["count"])))
            }
        }
        return StatsColumn(
            name: raw["name"] as? String ?? "",
            storageType: raw["storage_type"] as? String ?? "",
            detected: raw["detected"] as? String,
            parsedPercent: double(raw["parsed_percent"]),
            unparsed: int64(raw["unparsed"]),
            count: int64(raw["count"]),
            nulls: int64(raw["nulls"]),
            nullPercent: double(raw["null_percent"]) ?? 0,
            nullsScope: raw["nulls_scope"] as? String ?? "scanned",
            distinct: raw["distinct"] == nil ? nil : int64(raw["distinct"]),
            distinctExact: bool(raw["distinct_exact"]),
            min: raw["min"] as? String,
            max: raw["max"] as? String,
            mean: raw["mean"] as? String,
            median: raw["median"] as? String,
            stddev: raw["stddev"] as? String,
            p25: raw["p25"] as? String,
            p75: raw["p75"] as? String,
            p95: raw["p95"] as? String,
            p99: raw["p99"] as? String,
            minNumber: double(raw["min_number"]),
            maxNumber: double(raw["max_number"]),
            medianNumber: double(raw["median_number"]),
            medianLow: double(raw["median_low"]),
            medianHigh: double(raw["median_high"]),
            medianLowText: raw["median_low_text"] as? String,
            medianHighText: raw["median_high_text"] as? String,
            p95Number: double(raw["p95_number"]),
            p99Number: double(raw["p99_number"]),
            minCount: optionalInt64(raw["min_count"]),
            maxCount: optionalInt64(raw["max_count"]),
            medianCount: optionalInt64(raw["median_count"]),
            p95Count: optionalInt64(raw["p95_count"]),
            p99Count: optionalInt64(raw["p99_count"]),
            percentilesExact: bool(raw["percentiles_exact"]),
            temporal: bool(raw["temporal"]),
            top: top,
            values: values,
            valuesCapped: bool(raw["values_capped"])
        )
    }

    private static func int64(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }

    private static func optionalInt64(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private static func uint64(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? (value as? Bool) ?? false
    }
}

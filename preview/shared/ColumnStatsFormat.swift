import Foundation

/// Display text for the Stats view. Detection and the numeric summary are
/// computed in the Rust scanner; these labels only format that result.
enum ColumnStatsFormat {
    /// Matches `PARSE_THRESHOLD` in `native/parquet_preview/src/detect.rs`.
    /// A string column is inferred only when at least this share of its
    /// non-empty values parse as the detected type.
    static let inferenceThresholdPercent = 95.0

    struct InferredMarker: Equatable {
        var label: String
        var tooltip: String
        var partial: Bool
    }

    static func typeLabel(storage: String, detected: String?, parsedPercent: Double?, unparsed: Int64 = 0) -> String {
        inferredMarker(storage: storage, detected: detected, parsedPercent: parsedPercent, unparsed: unparsed)?.label ?? storage
    }

    static func inferredTypeName(_ detected: String) -> String {
        switch detected {
        case "int": return "int64"
        case "decimal": return "double"
        default: return detected
        }
    }

    static func inferredMarker(storage: String, detected: String?, parsedPercent: Double?, unparsed: Int64) -> InferredMarker? {
        guard let detected, let parsedPercent, parsedPercent.isFinite else { return nil }
        guard parsedPercent + 0.0001 >= inferenceThresholdPercent else { return nil }
        let name = inferredTypeName(detected)
        let partial = parsedPercent < 100
        let label = "\(storage) → \(name) (inferred)"
        let tooltip: String
        if partial {
            let skipped = unparsed == 1 ? "1 value doesn't" : "\(unparsed) values don't"
            tooltip = "\(formatPercent(parsedPercent))% parse as \(name); \(skipped). Show values that don't parse"
        } else {
            tooltip = "Every non-empty value parses as \(name). The stored type is still \(storage)."
        }
        return InferredMarker(label: label, tooltip: tooltip, partial: partial)
    }

    static func nullLabel(nulls: Int64, percent: Double) -> String {
        "\(nulls) (\(formatPercent(percent))%)"
    }

    static func distinctLabel(distinct: Int64?, exact: Bool) -> String {
        guard let distinct else { return "" }
        if exact {
            return "\(distinct)"
        }
        return "≥ \(distinct) (approximate)"
    }

    static func partialNote(scanned: UInt64, fileRows: Int64) -> String {
        "Stats other than footer min/max/nulls are based on the first \(scanned) of \(fileRows) rows."
    }

    static func topLabel(_ values: [(String, Int64)]) -> String {
        values.map { "\($0.0) (\($0.1))" }.joined(separator: ", ")
    }

    static func formatPercent(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

import Foundation

/// Display text for the Stats view. Detection and the numeric summary are
/// computed in the Rust scanner; these labels only format that result.
enum ColumnStatsFormat {
    static func typeLabel(storage: String, detected: String?, parsedPercent: Double?) -> String {
        guard let detected, let parsedPercent, parsedPercent.isFinite else { return storage }
        return "\(storage) → \(detected) (\(formatPercent(parsedPercent))% parsed)"
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

    private static func formatPercent(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

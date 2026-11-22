import Foundation

// Per-column statistics for the Quick Look Data tab's Stats view, over the rows the preview
// loaded (ParquetRowReader), not the whole file. Each figure that selects rows carries the
// column filter that shows them (ParquetDataTab.script syntax), so the page can link it.
public enum ParquetColumnStats {
    // A string column counts as inferred when at least this share of its non-empty values parse.
    public static let inferenceThresholdPercent = 95.0
    public static let topValueCount = 5

    public struct Figure: Equatable, Codable {
        public var text: String
        // Column filter that selects the rows behind the figure; nil when it is not a link.
        public var filter: String?
        public init(_ text: String, filter: String? = nil) {
            self.text = text
            self.filter = filter
        }
    }

    public struct Column: Equatable, Codable {
        public var name = ""
        public var type = ""
        public var kind = ""
        public var rows = 0
        public var nulls = Figure("0")
        public var nullPercent = 0.0
        public var distinct = 0
        // Set when the preview could not read the column; there are no other figures then.
        public var unreadable = false
        // Inferred type of a text column ("int64", "double", "bool", "date"), its share in
        // percent, and the values that do not parse (with the filter showing them).
        public var inferred: String?
        public var inferredLabel: String?
        public var unparsed: Figure?
        public var min: Figure?
        public var max: Figure?
        public var mean: String?
        public var stddev: String?
        public var p25: Figure?
        public var median: Figure?
        public var p75: Figure?
        public var p95: Figure?
        public var p99: Figure?
        public var top: [TopValue] = []
    }

    public struct TopValue: Equatable, Codable {
        public var value: String
        public var count: Int
        public var filter: String
    }

    // Same patterns as `not int` / `not number` / `not bool` / `not date` in ParquetDataTab.script.
    static let intPattern = try! NSRegularExpression(pattern: "^[+-]?[0-9]+$")
    static let numberPattern = try! NSRegularExpression(pattern: "^[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?$")
    static let boolPattern = try! NSRegularExpression(pattern: "^(true|false)$", options: [.caseInsensitive])
    static let datePattern = try! NSRegularExpression(pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}(:[0-9]{2}(\\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?)?$")

    static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return pattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    public static func number(_ text: String) -> Double? {
        guard matches(numberPattern, text), let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else { return nil }
        return value
    }

    // types: footer type label per column (for display); kinds: ParquetDataTab.columnKinds.
    public static func compute(table: ParquetRowReader.Table, types: [String], kinds: [String]) -> [Column] {
        table.columns.enumerated().map { c, name in
            let values = table.rows.map { c < $0.count ? $0[c] : nil }
            return column(
                name: name,
                type: c < types.count ? types[c] : "",
                kind: c < kinds.count ? kinds[c] : "text",
                values: values,
                unreadable: c < table.columnNotes.count && table.columnNotes[c] != nil
            )
        }
    }

    public static func column(name: String, type: String, kind: String, values: [String?], unreadable: Bool = false) -> Column {
        var stats = Column()
        stats.name = name
        stats.type = type
        stats.kind = kind
        stats.rows = values.count
        if unreadable {
            stats.unreadable = true
            return stats
        }
        let present = values.compactMap { $0 }
        let nulls = values.count - present.count
        stats.nulls = Figure(formatCount(nulls), filter: nulls > 0 ? "is null" : nil)
        stats.nullPercent = values.isEmpty ? 0 : Double(nulls) * 100 / Double(values.count)

        var counts: [String: Int] = [:]
        for value in present { counts[value, default: 0] += 1 }
        stats.distinct = counts.count
        // Only values that repeat: a list of values seen once says nothing.
        stats.top = counts.filter { $0.value > 1 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(topValueCount)
            .map { TopValue(value: $0.key, count: $0.value, filter: "=" + $0.key) }
        if kind == "nested" { return stats }

        var numeric = kind == "number"
        if kind == "text" {
            let nonEmpty = present.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !nonEmpty.isEmpty {
                // Most specific first: every int is also a number.
                let candidates: [(String, String, NSRegularExpression)] = [
                    ("int64", "int", intPattern), ("double", "number", numberPattern),
                    ("bool", "bool", boolPattern), ("date", "date", datePattern),
                ]
                for (label, token, pattern) in candidates {
                    let parsed = nonEmpty.filter { matches(pattern, $0) }.count
                    let percent = Double(parsed) * 100 / Double(nonEmpty.count)
                    guard percent + 0.0001 >= inferenceThresholdPercent else { continue }
                    stats.inferred = label
                    let missed = nonEmpty.count - parsed
                    if missed == 0 {
                        stats.inferredLabel = "\(type) → \(label) (inferred)"
                    } else {
                        stats.inferredLabel = "\(label), except \(formatPercent(100 - percent))%"
                        stats.unparsed = Figure(formatCount(missed), filter: "not " + token)
                    }
                    numeric = token == "int" || token == "number"
                    break
                }
            }
        }

        if numeric {
            let parsed = present.compactMap { text in number(text).map { (text, $0) } }
                .sorted { $0.1 < $1.1 }
            guard !parsed.isEmpty else { return stats }
            let n = Double(parsed.count)
            let mean = parsed.reduce(0) { $0 + $1.1 } / n
            stats.mean = formatNumber(mean)
            if parsed.count > 1 {
                let variance = parsed.reduce(0) { $0 + ($1.1 - mean) * ($1.1 - mean) } / (n - 1)
                stats.stddev = formatNumber(variance.squareRoot())
            }
            // Nearest rank, so every percentile is a value that occurs in the rows.
            func rank(_ p: Double) -> String { parsed[max(0, Int((p / 100 * n).rounded(.up)) - 1)].0 }
            stats.min = Figure(parsed[0].0, filter: "<=" + parsed[0].0)
            stats.max = Figure(parsed[parsed.count - 1].0, filter: ">=" + parsed[parsed.count - 1].0)
            stats.p25 = Figure(rank(25), filter: "<=" + rank(25))
            stats.median = Figure(rank(50), filter: "=" + rank(50))
            stats.p75 = Figure(rank(75), filter: ">=" + rank(75))
            stats.p95 = Figure(rank(95), filter: ">=" + rank(95))
            stats.p99 = Figure(rank(99), filter: ">=" + rank(99))
        } else if !present.isEmpty {
            // Dates and timestamps are ISO text, so text order is time order.
            let low = present.min()!, high = present.max()!
            stats.min = Figure(low, filter: "=" + low)
            stats.max = Figure(high, filter: "=" + high)
        }
        return stats
    }

    static func formatCount(_ value: Int) -> String { String(value) }

    // A tenth of a percent, without a trailing ".0".
    static func formatPercent(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    static func formatNumber(_ value: Double) -> String {
        String(format: "%.6g", value)
    }
}

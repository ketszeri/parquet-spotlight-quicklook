import Foundation

enum ColumnSortKind: Equatable {
    case number
    case date
    case text
}

enum SortDirection: Equatable {
    case ascending
    case descending
    case off
}

struct PreviewCellValue: Equatable {
    var text: String?
    var title: String?
    var truncated: Bool

    static func value(_ text: String?) -> PreviewCellValue {
        PreviewCellValue(text: text, title: nil, truncated: false)
    }
}

struct RowPreviewQuery: Equatable {
    var peekCount: Int
    var globalFilter: String
    var columnFilters: [Int: String]
    var sortColumn: Int?
    var sortDirection: SortDirection
}

enum RowPreviewLogic {
    /// `nil` means the Rust decoder must not be called.
    static func decodeRowLimit(showRowPreview: Bool, requested: Int) -> Int? {
        guard showRowPreview else { return nil }
        return RowPreviewDefaults.snapRowCount(requested)
    }

    static func kind(forType typeName: String) -> ColumnSortKind {
        let name = typeName.lowercased()
        if name.hasPrefix("date") || name.hasPrefix("timestamp") {
            return .date
        }
        if name.hasPrefix("int")
            || name.hasPrefix("uint")
            || name.hasPrefix("float")
            || name.hasPrefix("double")
            || name.hasPrefix("decimal") {
            return .number
        }
        return .text
    }

    /// Click cycle for one column: ascending, descending, then back to file order.
    static func cycleDirection(_ current: SortDirection) -> SortDirection {
        switch current {
        case .off: return .ascending
        case .ascending: return .descending
        case .descending: return .off
        }
    }

    static func visibleIndexes(rows: [[PreviewCellValue]], kinds: [ColumnSortKind], query: RowPreviewQuery) -> [Int] {
        let matched = rows.indices.filter { matches(row: rows[$0], global: query.globalFilter, columnFilters: query.columnFilters) }
        let ordered = order(matched, rows: rows, kinds: kinds, query: query)
        let peek = max(0, query.peekCount)
        if ordered.count <= peek {
            return ordered
        }
        return Array(ordered.prefix(peek))
    }

    static func matchCount(rows: [[PreviewCellValue]], query: RowPreviewQuery) -> Int {
        rows.indices.reduce(0) { count, index in
            count + (matches(row: rows[index], global: query.globalFilter, columnFilters: query.columnFilters) ? 1 : 0)
        }
    }

    static func filterIsActive(_ query: RowPreviewQuery) -> Bool {
        if !query.globalFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return query.columnFilters.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func summary(shown: Int, fileRows: Int64, loaded: Int, matched: Int, filterActive: Bool, hiddenColumns: Int) -> String {
        var parts: [String] = []
        if Int64(shown) < fileRows {
            parts.append("Showing \(shown) of \(fileRows) rows.")
        } else if shown == 1 {
            parts.append("Showing 1 row.")
        } else {
            parts.append("Showing \(shown) rows.")
        }
        if filterActive {
            parts.append("\(matched) of \(loaded) loaded rows match the filter.")
        } else if Int64(loaded) < fileRows && shown != loaded {
            parts.append("\(loaded) rows loaded.")
        }
        if hiddenColumns > 0 {
            parts.append("\(hiddenColumns) columns hidden.")
        }
        return parts.joined(separator: " ")
    }

    private static func matches(row: [PreviewCellValue], global: String, columnFilters: [Int: String]) -> Bool {
        let needle = global.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            let any = row.contains { ($0.text ?? "").lowercased().contains(needle) }
            if !any { return false }
        }
        for (index, raw) in columnFilters {
            let columnNeedle = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if columnNeedle.isEmpty { continue }
            guard index >= 0, index < row.count else { return false }
            if !(row[index].text ?? "").lowercased().contains(columnNeedle) { return false }
        }
        return true
    }

    private static func order(_ indexes: [Int], rows: [[PreviewCellValue]], kinds: [ColumnSortKind], query: RowPreviewQuery) -> [Int] {
        guard query.sortDirection != .off, let column = query.sortColumn, column >= 0 else {
            return indexes
        }
        let kind = column < kinds.count ? kinds[column] : .text
        let present = indexes.filter { column < rows[$0].count && rows[$0][column].text != nil }
        let missing = indexes.filter { column >= rows[$0].count || rows[$0][column].text == nil }
        let sorted = present.sorted { left, right in
            let lhs = rows[left][column].text ?? ""
            let rhs = rows[right][column].text ?? ""
            let cmp = compare(lhs, rhs, kind: kind)
            if cmp == .orderedSame { return left < right }
            if query.sortDirection == .descending {
                return cmp == .orderedDescending
            }
            return cmp == .orderedAscending
        }
        return sorted + missing
    }

    private static func compare(_ lhs: String, _ rhs: String, kind: ColumnSortKind) -> ComparisonResult {
        switch kind {
        case .number:
            if let left = Decimal(string: lhs), let right = Decimal(string: rhs) {
                if left < right { return .orderedAscending }
                if left > right { return .orderedDescending }
                return .orderedSame
            }
            return foldedCompare(lhs, rhs)
        case .date, .text:
            return foldedCompare(lhs, rhs)
        }
    }

    /// Fold case with the POSIX locale, then compare.
    ///
    /// `String.compare(_:options:locale:)` with `en_US_POSIX` uses that locale's
    /// binary collation and ignores `.caseInsensitive`, which sorted "C" before
    /// "a" on the macOS CI runner. Folding first keeps the order stable across
    /// locales and still applies numeric ordering ("a2" before "a10").
    private static func foldedCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let locale = Locale(identifier: "en_US_POSIX")
        return lhs.lowercased(with: locale).compare(
            rhs.lowercased(with: locale),
            options: [.numeric],
            locale: locale
        )
    }
}

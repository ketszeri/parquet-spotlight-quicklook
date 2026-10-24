import Foundation

enum RowPreviewCaps {
    static let hardMaxRows = UInt32(RowPreviewDefaults.hardMaxRows)
    static let hardMaxColumns = UInt32(RowPreviewDefaults.hardMaxColumns)
    static let hardMaxBytes = RowPreviewDefaults.hardMaxBytes
    static let hardMaxMillis = RowPreviewDefaults.hardMaxMillis
    static let defaultRows = RowPreviewDefaults.defaultRowCount
    static let defaultColumns = RowPreviewDefaults.hardMaxColumns
}

struct RowPreviewCell {
    var text: String?
    var truncated: Bool
    var title: String?
    var number: Double?
    var kinds: [String]
}

struct RowPreviewTable {
    var columns: [(name: String, typeName: String)]
    var rows: [[RowPreviewCell]]
    var totalColumns: Int
    var shownColumns: Int
    var hiddenColumns: Int
    var shownRows: Int
    var fileRows: Int64
}

enum RowPreviewResult {
    case table(RowPreviewTable)
    case failed(String)
}

enum RowPreviewDecoder {
    static func read(path: String, maxRows: Int, maxColumns: Int) -> RowPreviewResult {
        let rows = UInt32(clamping: max(1, min(maxRows, Int(RowPreviewCaps.hardMaxRows))))
        let cols = UInt32(clamping: max(1, min(maxColumns, Int(RowPreviewCaps.hardMaxColumns))))
        var limits = parquet_preview_limits(
            max_rows: rows,
            max_columns: cols,
            max_bytes: RowPreviewCaps.hardMaxBytes,
            max_millis: RowPreviewCaps.hardMaxMillis
        )
        return path.withCString { cPath in
            var jsonPtr: UnsafeMutablePointer<CChar>?
            var errPtr: UnsafeMutablePointer<CChar>?
            let rc = parquet_preview_read(cPath, &limits, &jsonPtr, &errPtr)
            defer {
                if let jsonPtr {
                    parquet_preview_string_free(jsonPtr)
                }
                if let errPtr {
                    parquet_preview_string_free(errPtr)
                }
            }
            if rc != 0 {
                let message = errPtr.map { String(cString: $0) } ?? "row preview could not decode this file"
                return .failed(String(message.prefix(180)))
            }
            guard let jsonPtr else {
                return .failed("row preview could not decode this file")
            }
            let json = String(cString: jsonPtr)
            guard json.utf8.count <= 16 * 1024 * 1024,
                  let data = json.data(using: .utf8),
                  let table = parseTable(data) else {
                return .failed("row preview could not decode this file")
            }
            return .table(table)
        }
    }

    private static func parseTable(_ data: Data) -> RowPreviewTable? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawColumns = obj["columns"] as? [[String: Any]],
              let rawRows = obj["rows"] as? [Any] else {
            return nil
        }
        var columns: [(name: String, typeName: String)] = []
        for column in rawColumns {
            let name = column["name"] as? String ?? ""
            let typeName = column["type"] as? String ?? ""
            columns.append((name, typeName))
        }
        var rows: [[RowPreviewCell]] = []
        for rawRow in rawRows {
            guard let cells = rawRow as? [Any] else { continue }
            var parsed: [RowPreviewCell] = []
            for rawCell in cells {
                guard let cell = rawCell as? [String: Any] else {
                    parsed.append(RowPreviewCell(text: nil, truncated: false, title: nil, number: nil, kinds: []))
                    continue
                }
                let text: String?
                if cell["text"] == nil || cell["text"] is NSNull {
                    text = nil
                } else {
                    text = cell["text"] as? String
                }
                let truncated = (cell["truncated"] as? Bool) ?? (cell["truncated"] as? NSNumber)?.boolValue ?? false
                let title = cell["title"] as? String
                let number = (cell["number"] as? NSNumber)?.doubleValue
                let kinds = cell["kinds"] as? [String] ?? []
                parsed.append(RowPreviewCell(text: text, truncated: truncated, title: title, number: number, kinds: kinds))
            }
            rows.append(parsed)
        }
        return RowPreviewTable(
            columns: columns,
            rows: rows,
            totalColumns: intValue(obj["total_columns"]),
            shownColumns: intValue(obj["shown_columns"]),
            hiddenColumns: intValue(obj["hidden_columns"]),
            shownRows: intValue(obj["shown_rows"]),
            fileRows: int64Value(obj["file_rows"])
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }
}

enum RowPreviewHTML {
    static func tableHTML(_ table: RowPreviewTable, footerNote: String) -> String {
        var header = ""
        header += "<th class=\"rownum\">#</th>"
        for column in table.columns {
            header += "<th><div class=\"colname\">\(escape(column.name))</div><div class=\"coltype\">\(escape(column.typeName))</div></th>"
        }
        var body = ""
        if table.rows.isEmpty {
            let span = max(1, table.columns.count + 1)
            body = "<tr><td class=\"muted\" colspan=\"\(span)\">No rows in this file.</td></tr>"
        } else {
            for (index, row) in table.rows.enumerated() {
                body += "<tr><td class=\"rownum\">\(index + 1)</td>"
                for cell in row {
                    body += cellHTML(cell)
                }
                body += "</tr>"
            }
        }
        let note = footerNote.isEmpty ? "" : "<div class=\"note\">\(escape(footerNote))</div>"
        return """
        \(note)
        <div class="wrap">
          <table class="grid">
            <thead><tr>\(header)</tr></thead>
            <tbody>\(body)</tbody>
          </table>
        </div>
        """
    }

    private static func cellHTML(_ cell: RowPreviewCell) -> String {
        guard let text = cell.text else {
            return "<td class=\"cell null\">null</td>"
        }
        var attributes = ""
        if let title = cell.title, !title.isEmpty {
            attributes += " title=\"\(escape(title))\""
        }
        let klass = cell.truncated ? "cell trunc" : "cell"
        return "<td class=\"\(klass)\"\(attributes)>\(escape(text))</td>"
    }

    private static func escape(_ value: String) -> String {
        var out = value.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }
}

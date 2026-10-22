import Foundation

/// Paths and checks shared by the Quick Look extension and the host app.
///
/// The extension is sandboxed with user-selected read-only access, so it
/// cannot show a save panel that writes outside its container. It writes the
/// workbook under its own home. The unsandboxed host reads that container
/// path, checks the id, and copies the file where the user chooses.
///
/// The app group is not used. An ad-hoc signature on recent macOS often
/// rejects the group, and the extension container is already writable.
enum ExcelHandoff {
    static let scheme = "parquetquicklook"
    static let notificationName = Notification.Name("com.rkrug.parquetindexer.exportReady")
    static let containerBundleID = "com.rkrug.parquetindexer.previewhost.preview"
    static let relativeExports = "Library/Application Support/ParquetPreview/Exports"
    static let excelMaxRows = 1_048_576
    static let excelMaxColumns = 16_384

    struct Request: Codable {
        var id: String
        var suggestedName: String
        var mode: String
        var sheets: Int
        var rows: Int64
        var columns: Int
        var truncatedColumns: Int
    }

    static func isExportID(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5,
              parts[0].count == 8,
              parts[1].count == 4,
              parts[2].count == 4,
              parts[3].count == 4,
              parts[4].count == 12 else {
            return false
        }
        return id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// Directory the extension writes. `home` is `NSHomeDirectory()` inside the extension.
    static func exportsDirectory(home: URL) -> URL {
        home.appendingPathComponent(relativeExports, isDirectory: true)
    }

    /// Same files, as seen from the unsandboxed host's real home directory.
    static func containerExportsDirectory(realHome: URL) -> URL {
        realHome
            .appendingPathComponent("Library/Containers/\(containerBundleID)/Data/\(relativeExports)", isDirectory: true)
    }

    /// `directory/<uuid>.<ext>`, or nil when the id could leave that directory.
    static func containedFile(directory: URL, id: String, ext: String) -> URL? {
        guard isExportID(id), ext == "xlsx" || ext == "json" else { return nil }
        let name = "\(id).\(ext)"
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let file = directory.appendingPathComponent(name, isDirectory: false).standardizedFileURL.resolvingSymlinksInPath()
        guard file.lastPathComponent == name else { return nil }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPath) else { return nil }
        return file
    }

    static func exportURL(id: String) -> URL? {
        guard isExportID(id) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "export"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    static func id(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "export" else { return nil }
        guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "id" })?
            .value,
              isExportID(id) else {
            return nil
        }
        return id
    }

    static func suggestedName(sourcePath: String, mode: String) -> String {
        var base = URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        if base.isEmpty || base == "." || base == "/" {
            base = "export"
        }
        let cleaned = String(base.map { character -> Character in
            if character == "/" || character == "\\" || character == ":" { return "-" }
            return character
        })
        if mode == "view" {
            return "\(cleaned)-rows.xlsx"
        }
        return "\(cleaned).xlsx"
    }

    static func limitNote(rows: Int64, sheets: Int, truncatedColumns: Int) -> String {
        var parts: [String] = []
        if sheets > 1 {
            parts.append("Excel allows \(excelMaxRows) rows on a sheet, including the header. This file has \(rows) rows, so the export uses \(sheets) sheets.")
        }
        if truncatedColumns > 0 {
            parts.append("Excel allows \(excelMaxColumns) columns. \(truncatedColumns) columns are left out.")
        }
        return parts.joined(separator: " ")
    }

    /// Columns in visual order. Null cells stay JSON null.
    static func viewJSON(columns: [(name: String, type: String)], rows: [[String?]], order: [Int]) -> String? {
        let chosen = order.filter { $0 >= 0 && $0 < columns.count }
        let payloadColumns: [[String: String]] = chosen.map { index in
            ["name": columns[index].name, "type": columns[index].type]
        }
        let payloadRows: [[Any]] = rows.map { row in
            chosen.map { index -> Any in
                guard index < row.count, let text = row[index] else { return NSNull() }
                return text
            }
        }
        let object: [String: Any] = ["columns": payloadColumns, "rows": payloadRows]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    static func writeRequest(_ request: Request, to url: URL) throws {
        let data = try JSONEncoder().encode(request)
        try data.write(to: url, options: .atomic)
    }

    static func readRequest(at url: URL) -> Request? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Request.self, from: data)
    }
}

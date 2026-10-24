import AppKit
import Foundation

/// `Result` requires its failure type to conform to `Error`. The export
/// messages are plain strings, so the conformance lives next to those calls.
extension String: @retroactive Error {}

struct ExcelPlan {
    var rows: Int64
    var columns: Int
    var sheets: Int
    var truncatedColumns: Int

    var exceedsExcelLimits: Bool { sheets > 1 || truncatedColumns > 0 }
}

/// C ABI wrapper. Calls block, so the preview must use a background queue.
enum ExcelExporter {
    static func plan(path: String) -> Result<ExcelPlan, String> {
        path.withCString { cPath in
            var plan = parquet_preview_export_plan(rows: 0, columns: 0, sheets: 0, truncated_columns: 0)
            var error: UnsafeMutablePointer<CChar>?
            let rc = parquet_preview_plan(cPath, &plan, &error)
            return finish(rc: rc, error: error, plan: plan)
        }
    }

    static func exportFile(
        source: String,
        dest: String,
        progress: UnsafeMutablePointer<parquet_preview_export_progress>
    ) -> Result<Void, String> {
        source.withCString { cSource in
            dest.withCString { cDest in
                var error: UnsafeMutablePointer<CChar>?
                let rc = parquet_preview_export_file(cSource, cDest, progress, &error)
                defer { if let error { parquet_preview_string_free(error) } }
                if rc != 0 {
                    return .failure(message(error))
                }
                return .success(())
            }
        }
    }

    static func exportTable(json: String, dest: String) -> Result<ExcelPlan, String> {
        json.withCString { cJSON in
            dest.withCString { cDest in
                var plan = parquet_preview_export_plan(rows: 0, columns: 0, sheets: 0, truncated_columns: 0)
                var error: UnsafeMutablePointer<CChar>?
                let rc = parquet_preview_export_table(cJSON, cDest, &plan, &error)
                return finish(rc: rc, error: error, plan: plan)
            }
        }
    }

    private static func finish(
        rc: Int32,
        error: UnsafeMutablePointer<CChar>?,
        plan: parquet_preview_export_plan
    ) -> Result<ExcelPlan, String> {
        defer { if let error { parquet_preview_string_free(error) } }
        if rc != 0 {
            return .failure(message(error))
        }
        return .success(ExcelPlan(
            rows: plan.rows,
            columns: Int(plan.columns),
            sheets: Int(plan.sheets),
            truncatedColumns: Int(plan.truncated_columns)
        ))
    }

    private static func message(_ error: UnsafeMutablePointer<CChar>?) -> String {
        let text = error.map { String(cString: $0) } ?? "Excel export failed"
        return String(text.prefix(180))
    }
}

enum ExcelStaging {
    struct Staged {
        var id: String
        var xlsx: URL
        var request: URL
    }

    static func make(id: String) -> Staged? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let directory = ExcelHandoff.exportsDirectory(home: home)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard let xlsx = ExcelHandoff.containedFile(directory: directory, id: id, ext: "xlsx"),
              let request = ExcelHandoff.containedFile(directory: directory, id: id, ext: "json") else {
            return nil
        }
        return Staged(id: id, xlsx: xlsx, request: request)
    }

    /// The appex lives at `App.app/Contents/PlugIns/Name.appex`.
    static func hostAppURL() -> URL? {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard app.pathExtension == "app" else { return nil }
        return app
    }

    static func launchHost(id: String) {
        DistributedNotificationCenter.default().postNotificationName(
            ExcelHandoff.notificationName,
            object: id,
            userInfo: nil,
            deliverImmediately: true
        )
        guard let appURL = hostAppURL() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let url = ExcelHandoff.exportURL(id: id) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration, completionHandler: nil)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
        }
    }
}

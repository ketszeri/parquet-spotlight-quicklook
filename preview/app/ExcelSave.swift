import AppKit
import Foundation
import UniformTypeIdentifiers

/// Save panel for a workbook the Quick Look extension already wrote.
///
/// The id has to be a UUID, and both files have to stay inside the extension
/// container's Exports directory. The panel runs in this unsandboxed app.
enum ExcelSave {
    private static var showing: Set<String> = []

    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: ExcelHandoff.notificationName,
            object: nil,
            queue: .main
        ) { note in
            if let id = note.object as? String {
                present(id: id)
            } else {
                presentPending()
            }
        }
    }

    static func handle(url: URL) {
        if let id = ExcelHandoff.id(from: url) {
            present(id: id)
        }
    }

    static func presentPending() {
        for directory in directories() {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.prefix(32) where name.hasSuffix(".json") {
                let id = String(name.dropLast(5))
                present(id: id)
            }
        }
    }

    /// The sandboxed extension's home is its container. A host build that is
    /// not sandboxed writes under the real home instead, so look in both.
    private static func directories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            ExcelHandoff.containerExportsDirectory(realHome: home),
            ExcelHandoff.exportsDirectory(home: home)
        ]
    }

    static func present(id: String) {
        guard ExcelHandoff.isExportID(id), !showing.contains(id) else { return }
        guard let located = directories().compactMap({ directory -> (URL, URL)? in
            guard let xlsx = ExcelHandoff.containedFile(directory: directory, id: id, ext: "xlsx"),
                  let requestURL = ExcelHandoff.containedFile(directory: directory, id: id, ext: "json"),
                  FileManager.default.fileExists(atPath: xlsx.path) else {
                return nil
            }
            return (xlsx, requestURL)
        }).first else {
            return
        }
        let xlsx = located.0
        let requestURL = located.1
        let values = try? xlsx.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return }
        let suggested = fileName(ExcelHandoff.readRequest(at: requestURL)?.suggestedName)
        showing.insert(id)
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.title = "Save Excel Workbook"
            panel.prompt = "Save"
            panel.nameFieldStringValue = suggested
            panel.canCreateDirectories = true
            if let xlsxType = UTType(filenameExtension: "xlsx") {
                panel.allowedContentTypes = [xlsxType]
            }
            let response = panel.runModal()
            showing.remove(id)
            if response == .OK, let destination = panel.url {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: xlsx, to: destination)
                    try? FileManager.default.removeItem(at: xlsx)
                    try? FileManager.default.removeItem(at: requestURL)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Could not save the Excel workbook"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            } else {
                try? FileManager.default.removeItem(at: xlsx)
                try? FileManager.default.removeItem(at: requestURL)
            }
        }
    }

    private static func fileName(_ suggested: String?) -> String {
        let base = URL(fileURLWithPath: suggested ?? "export.xlsx").lastPathComponent
        if base.isEmpty || base == "." || base == ".." || !base.lowercased().hasSuffix(".xlsx") {
            return "export.xlsx"
        }
        return base
    }
}

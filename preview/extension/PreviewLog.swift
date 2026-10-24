import Foundation
import os

/// Unified log for the Quick Look extension. Subsystem `com.rkrug.parquetindexer`,
/// category `preview`. Messages are public so a real-Mac `log show` is readable.
enum PreviewLog {
    private static let log = OSLog(subsystem: "com.rkrug.parquetindexer", category: "preview")

    static func stage(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
        mirror(message)
    }

    static func error(_ message: String) {
        os_log("%{public}@", log: log, type: .error, message)
        mirror("ERROR \(message)")
    }

    private static func mirror(_ message: String) {
        guard ProcessInfo.processInfo.environment["PARQUET_PREVIEW_LOG"] == "1" else { return }
        fputs("preview: \(message)\n", stderr)
    }
}

/// Calls the Quick Look completion handler once, on the main queue.
final class PreviewCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func finish(_ error: Error?) {
        lock.lock()
        let call = handler
        handler = nil
        lock.unlock()
        guard let call else {
            PreviewLog.error("handler.duplicate")
            return
        }
        let invoke = {
            if let error {
                PreviewLog.error("handler.error \(error.localizedDescription)")
            } else {
                PreviewLog.stage("handler.ok")
            }
            call(error)
        }
        if Thread.isMainThread {
            invoke()
        } else {
            DispatchQueue.main.async(execute: invoke)
        }
    }
}

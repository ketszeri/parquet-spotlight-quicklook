import AppKit
import Foundation

/// Loads the preview bundle and drives QLPreviewingController the way Finder does:
/// instantiate the principal class, let it load its view, call preparePreviewOfFile,
/// then put the view in a window and lay it out. This runs on macOS CI, which never
/// hosts the appex inside Quick Look itself.
let arguments = CommandLine.arguments
if arguments.count < 4 {
    fputs("usage: preview-host <bundle> <parquet> <expected-status>\n", stderr)
    exit(2)
}

let bundleURL = URL(fileURLWithPath: arguments[1])
let fileURL = URL(fileURLWithPath: arguments[2])
let expected = arguments[3]

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

if let probe = ProcessInfo.processInfo.environment["PARQUET_PROBE_APPEX"], !probe.isEmpty {
    let appex = Bundle(url: URL(fileURLWithPath: probe))
    do {
        try appex?.loadAndReturnError()
        let name = appex?.classNamed("ParquetPreviewController")
        fputs("appex-load: ok class=\(name == nil ? "missing" : "ParquetPreviewController")\n", stderr)
    } catch {
        fputs("appex-load: \(error.localizedDescription)\n", stderr)
    }
}

guard let bundle = Bundle(url: bundleURL) else {
    fputs("bundle url failed\n", stderr)
    exit(1)
}
do {
    try bundle.loadAndReturnError()
} catch {
    fputs("bundle load failed: \(error)\n", stderr)
    exit(1)
}
guard let controllerClass = bundle.classNamed("ParquetPreviewController") as? NSViewController.Type else {
    fputs("ParquetPreviewController was not found in the bundle\n", stderr)
    exit(1)
}

let viewController = controllerClass.init(nibName: nil, bundle: nil)
_ = viewController.view

var calls = 0
var previewError: Error?
let deadline = Date().addingTimeInterval(8)
ParquetHostPrepare(viewController, fileURL) { error in
    calls += 1
    previewError = error
}
while calls == 0 && Date() < deadline {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
if calls != 1 {
    fputs("handler calls=\(calls), expected 1\n", stderr)
    exit(1)
}
if let previewError {
    fputs("preview error: \(previewError.localizedDescription)\n", stderr)
    exit(1)
}

let status = viewController.value(forKey: "previewPreparationStatus") as? String ?? ""
let size = viewController.preferredContentSize
fputs("status=\(status) size=\(Int(size.width))x\(Int(size.height))\n", stderr)
if status != expected {
    fputs("expected status \(expected)\n", stderr)
    exit(1)
}
if !(size.width >= 420 && size.height >= 280 && size.width <= 4096 && size.height <= 4096) {
    fputs("preferredContentSize out of bounds\n", stderr)
    exit(1)
}

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
    styleMask: [.titled, .resizable],
    backing: .buffered,
    defer: false
)
window.contentViewController = viewController
let layoutError = ParquetCatchException {
    window.contentViewController = viewController
    window.layoutIfNeeded()
    viewController.view.layoutSubtreeIfNeeded()
}
if let layoutError {
    fputs("layout exception: \(layoutError.localizedDescription)\n", stderr)
    exit(1)
}
RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
if calls != 1 {
    fputs("handler calls=\(calls) after layout, expected 1\n", stderr)
    exit(1)
}
if expected == "rows" {
    guard let aligned = viewController.perform(NSSelectorFromString("exerciseFilterAlignmentForTest"))?
        .takeUnretainedValue() as? NSNumber, aligned.intValue == 1 else {
        fputs("filter fields do not match column rects after resize and scroll\n", stderr)
        exit(1)
    }
    fputs("filter alignment ok\n", stderr)
}
print("PASS: preview host \(status)")

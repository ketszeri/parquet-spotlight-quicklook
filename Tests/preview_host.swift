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
let mode = arguments.count >= 5 ? arguments[4] : "full"

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
if expected == "rows" && mode == "marker" {
    viewController.perform(NSSelectorFromString("selectStatsTabForTest"))
    let statsDeadline = Date().addingTimeInterval(12)
    var statsStatus = ""
    while Date() < statsDeadline {
        statsStatus = viewController.value(forKey: "statsPreparationStatus") as? String ?? ""
        if statsStatus == "ready" || statsStatus == "partial" || statsStatus == "failed" {
            break
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    fputs("marker stats status=\(statsStatus)\n", stderr)
    if statsStatus != "ready" && statsStatus != "partial" {
        fputs("expected stats status ready or partial\n", stderr)
        exit(1)
    }
    guard let report = viewController.perform(NSSelectorFromString("exerciseUnparsedLinkForTest"))?
        .takeUnretainedValue() as? String else {
        fputs("unparsed link exercise did not run\n", stderr)
        exit(1)
    }
    fputs("unparsed \(report)\n", stderr)
    if !report.contains("chip=price: not int64") || !report.contains("rows=4") || !report.contains("unparsed=4") {
        fputs("clicking the inferred marker should show the 4 unparsed rows\n", stderr)
        exit(1)
    }
    if !report.contains("showing 4 of 4 unparsed") {
        fputs("the unparsed note should match the stats count\n", stderr)
        exit(1)
    }
    if !report.contains("kept=true") || !report.contains("keptRows=4") {
        fputs("changing the row count should keep the unparsed filter\n", stderr)
        exit(1)
    }
    if !report.contains("cleared=true") || !report.contains("tab=0") {
        fputs("clearing filters should remove the unparsed chip and leave the rows view\n", stderr)
        exit(1)
    }
    guard let prices = viewController.perform(NSSelectorFromString("exercisePricePercentilesForTest"))?
        .takeUnretainedValue() as? String else {
        fputs("price percentile exercise did not run\n", stderr)
        exit(1)
    }
    fputs("price percentiles \(prices)\n", stderr)
    let priceRequired = [
        "p95 rows=5 min=90 unparsed=0",
        "price ≥ p95",
        "kept=true narrowed=0 restored=5",
        "p25 rows=71 min=24 unparsed=0",
        "price ≥ p25",
        "tint=true",
        "type-style=link",
        "type=int64, except",
        "cleared=true"
    ]
    for piece in priceRequired where !prices.contains(piece) {
        fputs("price percentiles missing \(piece)\n", stderr)
        exit(1)
    }
} else if expected == "rows" {
    guard let aligned = viewController.perform(NSSelectorFromString("exerciseFilterAlignmentForTest"))?
        .takeUnretainedValue() as? NSNumber, aligned.intValue == 1 else {
        fputs("filter fields do not match column rects after resize and scroll\n", stderr)
        exit(1)
    }
    fputs("filter alignment ok\n", stderr)
    guard let editing = viewController.perform(NSSelectorFromString("exerciseFilterEditingForTest"))?
        .takeUnretainedValue() as? String else {
        fputs("filter editing exercise did not run\n", stderr)
        exit(1)
    }
    fputs("filter editing \(editing)\n", stderr)
    if editing.contains("editor=1") {
        let editingRequired = [
            "key=1",
            "panel=0",
            "text=0",
            "survived=1",
            "immediate=0",
            "reloads=1",
            "rows=1",
            "same=1",
            "writes=0",
            "restored=1"
        ]
        for piece in editingRequired where !editing.contains(piece) {
            fputs("filter editing missing \(piece)\n", stderr)
            exit(1)
        }
    } else {
        let fallbackRequired = ["key=0", "editor=0", "panel=1", "fallback-rows=1", "same=1", "writes=0"]
        for piece in fallbackRequired where !editing.contains(piece) {
            fputs("filter editing missing \(piece)\n", stderr)
            exit(1)
        }
    }
    guard let debounced = viewController.perform(NSSelectorFromString("exerciseFilterDebounceForTest"))?
        .takeUnretainedValue() as? String else {
        fputs("filter debounce exercise did not run\n", stderr)
        exit(1)
    }
    fputs("filter debounce \(debounced)\n", stderr)
    for piece in ["immediate=0", "reloads=1", "rows=1"] where !debounced.contains(piece) {
        fputs("filter debounce missing \(piece)\n", stderr)
        exit(1)
    }
    guard let sheet = viewController.perform(NSSelectorFromString("exerciseFilterSheetForTest"))?
        .takeUnretainedValue() as? String else {
        fputs("filter sheet exercise did not run\n", stderr)
        exit(1)
    }
    fputs("filter sheet \(sheet)\n", stderr)
    for piece in ["panel=1", "text=1", "rows=1", "cleared=3"] where !sheet.contains(piece) {
        fputs("filter sheet missing \(piece)\n", stderr)
        exit(1)
    }
    if sheet.contains("key=1") {
        if !sheet.contains("sheet=1") {
            fputs("a key window should present the filter as a sheet\n", stderr)
            exit(1)
        }
    } else if !sheet.contains("key=0") || !sheet.contains("sheet=0") {
        fputs("a window that is not key should present a floating filter panel\n", stderr)
        exit(1)
    }
    guard let standalone = viewController.perform(NSSelectorFromString("exerciseFilterStandalonePanelForTest"))?
        .takeUnretainedValue() as? String else {
        fputs("filter panel exercise did not run\n", stderr)
        exit(1)
    }
    fputs("filter panel \(standalone)\n", stderr)
    for piece in ["panel=1", "sheet=0", "text=1", "rows=1", "cleared=3"] where !standalone.contains(piece) {
        fputs("filter panel missing \(piece)\n", stderr)
        exit(1)
    }
    guard let excelPlan = viewController.perform(NSSelectorFromString("excelPlanForTest"))?
        .takeUnretainedValue() as? String else {
        fputs("excel plan missing\n", stderr)
        exit(1)
    }
    fputs("excel plan \(excelPlan)\n", stderr)
    if !excelPlan.hasPrefix("rows=3;") {
        fputs("expected an Excel plan for the 3-row fixture\n", stderr)
        exit(1)
    }
    guard let interactions = viewController.perform(NSSelectorFromString("exerciseInteractionsForTest"))?
        .takeUnretainedValue() as? String, interactions.hasPrefix("ok ") else {
        fputs("interaction exercise did not run\n", stderr)
        exit(1)
    }
    fputs("interactions \(interactions)\n", stderr)
    if !interactions.contains("filtered=1") {
        fputs("the alpha filter should leave one row; matching itself is unchanged\n", stderr)
        exit(1)
    }
    func waitForExport(_ selector: String) -> String {
        viewController.perform(NSSelectorFromString(selector))
        let exportDeadline = Date().addingTimeInterval(20)
        var banner = ""
        while Date() < exportDeadline {
            banner = viewController.perform(NSSelectorFromString("exportBannerForTest"))?
                .takeUnretainedValue() as? String ?? ""
            if banner.contains("Choose where to save")
                || banner.contains("unavailable")
                || banner.contains("could not")
                || banner.contains("cancelled") {
                return banner
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return banner
    }
    let viewExport = waitForExport("beginViewExcelExportForTest")
    fputs("view export \(viewExport)\n", stderr)
    if !viewExport.contains("Choose where to save") {
        fputs("rows-view export did not hand the workbook to the app\n", stderr)
        exit(1)
    }
    let fileExport = waitForExport("beginFileExcelExportForTest")
    fputs("file export \(fileExport)\n", stderr)
    if !fileExport.contains("Choose where to save") {
        fputs("whole-file export did not hand the workbook to the app\n", stderr)
        exit(1)
    }
    viewController.perform(NSSelectorFromString("selectStatsTabForTest"))
    let statsDeadline = Date().addingTimeInterval(12)
    var statsStatus = ""
    while Date() < statsDeadline {
        statsStatus = viewController.value(forKey: "statsPreparationStatus") as? String ?? ""
        if statsStatus == "ready" || statsStatus == "partial" || statsStatus == "failed" {
            break
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    fputs("stats status=\(statsStatus)\n", stderr)
    if statsStatus != "ready" && statsStatus != "partial" {
        fputs("expected stats status ready or partial\n", stderr)
        exit(1)
    }
    guard let links = viewController.perform(NSSelectorFromString("exerciseStatsLinksForTest"))?
        .takeUnretainedValue() as? String else {
        fputs("stats link exercise did not run\n", stderr)
        exit(1)
    }
    fputs("stats links \(links)\n", stderr)
    let required = [
        "null chip=label: is null rows=1",
        "kept=true column=true after=1 noted=true linkCleared=true columnRemains=true allClear=true",
        "distinct values=alpha,beta",
        "showing 2 of 2 distinct",
        "mode=label: distinct",
        "value=label = alpha",
        "order=name,type,count,nulls,distinct,min,mean,median,max,stddev,p25,p75,p95,p99,top",
        "style-min=text",
        "style-mean=text",
        "style-p25=link",
        "style-null=link",
        "min-click=false",
        "max-click=false",
        "median-click=false",
        "mean-click=false",
        "p25 chip=id ≥ p25",
        "p25 texts=1,2",
        "p75 chip=id ≥ p75",
        "p75 texts=2",
        "p95 chip=id ≥ p95",
        "p95 texts=2",
        "p99 chip=id ≥ p99",
        "p99 texts=2",
        "kept=true still=1"
    ]
    for piece in required where !links.contains(piece) {
        fputs("stats links missing \(piece)\n", stderr)
        exit(1)
    }
    viewController.perform(NSSelectorFromString("exerciseFallbackForTest"))
    if viewController.value(forKey: "previewPreparationStatus") as? String != "fallback" {
        fputs("fallback exercise did not report fallback\n", stderr)
        exit(1)
    }
}
print("PASS: preview host \(status)")

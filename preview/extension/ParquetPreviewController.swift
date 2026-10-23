import AppKit
import Foundation
import QuickLookUI

/// View-based Quick Look preview.
///
/// Data-based HTML replies do not run JavaScript inside Finder, so a sort box
/// drawn in that HTML would not work. `WKWebView` can run scripts, but the
/// sandboxed web process asks for `com.apple.security.network.client`, which
/// this extension does not have. The rows table is an `NSTableView` instead:
/// header clicks, the filter fields, and the row-count popup are real AppKit
/// controls. The scroll view is constrained to the window, so resizing the
/// preview resizes the table instead of leaving empty space under a fixed page.
@objc(ParquetPreviewController)
final class ParquetPreviewController: NSViewController, QLPreviewingController {
    /// `rows`, `schema`, `schema-only`, `fallback`, or `idle`. The host test reads this.
    @objc var previewPreparationStatus = "idle"
    private var quickLookView: ParquetQuickLookView?

    override func loadView() {
        PreviewLog.stage("loadView")
        let root = ParquetQuickLookView(frame: NSRect(origin: .zero, size: RowPreviewLayout.schemaOnlySize))
        quickLookView = root
        // Set the view only here. Replacing it later disconnects ViewBridge (Code=17).
        view = root
        preferredContentSize = RowPreviewLayout.clampedWindowSize(RowPreviewLayout.schemaOnlySize)
    }

    @objc(preparePreviewOfFileAtURL:completionHandler:)
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        PreviewLog.stage("prepare.begin \(url.lastPathComponent)")
        let completion = PreviewCompletion(handler)
        // Return before calling the handler so the view service is not re-entered.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                PreviewLog.error("prepare.released")
                completion.finish(NSError(
                    domain: "com.rkrug.parquetindexer.preview",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The preview was released before it finished."]
                ))
                return
            }
            self.prepareOnMain(url: url, completion: completion)
        }
    }

    private func prepareOnMain(url: URL, completion: PreviewCompletion) {
        PreviewLog.stage("prepare.main")
        var folderError: NSError?
        let failure = ParquetCatchException {
            ProcessInfo.processInfo.disableAutomaticTermination("Parquet Quick Look preview")
            folderError = self.buildPreview(of: url)
        }
        if let failure {
            PreviewLog.error("prepare.exception \(failure.localizedDescription)")
            let fallback = ParquetCatchException {
                self.installTextFallback(failure.localizedDescription)
            }
            if let fallback {
                PreviewLog.error("prepare.fallback.failed \(fallback.localizedDescription)")
                completion.finish(failure)
                return
            }
            completion.finish(nil)
            return
        }
        if let folderError {
            PreviewLog.stage("prepare.folder.skip")
            completion.finish(folderError)
            return
        }
        PreviewLog.stage("prepare.ready \(self.previewPreparationStatus)")
        completion.finish(nil)
    }

    private func buildPreview(of url: URL) -> NSError? {
        let root = quickLookView ?? (view as? ParquetQuickLookView)
        guard let root else {
            installTextFallback("The preview view was not loaded.")
            return nil
        }
        let provider = PreviewProvider()
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDirectory && provider.readDatasetMetadata(at: url, settings: provider.loadSettings()) == nil {
            PreviewLog.stage("prepare.folder.empty")
            return NSError(domain: "QLPreviewErrorDomain", code: 3, userInfo: nil)
        }
        let visible = visibleScreenSize()
        let status = root.configure(url: url, provider: provider, visibleSize: visible)
        previewPreparationStatus = status
        preferredContentSize = RowPreviewLayout.clampedWindowSize(root.previewSize)
        PreviewLog.stage("prepare.size \(Int(preferredContentSize.width))x\(Int(preferredContentSize.height))")
        return nil
    }

    /// `NSScreen` can throw or return nothing inside a Quick Look extension.
    /// A bad size must not cross the Quick Look boundary.
    private func visibleScreenSize() -> CGSize {
        var size = RowPreviewLayout.fallbackVisibleSize
        let failure = ParquetCatchException {
            let screen = NSScreen.main ?? NSScreen.screens.first
            size = RowPreviewLayout.clampedVisibleSize(screen?.visibleFrame.size ?? .zero)
        }
        if let failure {
            PreviewLog.error("screen.unavailable \(failure.localizedDescription)")
            return RowPreviewLayout.fallbackVisibleSize
        }
        PreviewLog.stage("screen \(Int(size.width))x\(Int(size.height))")
        return size
    }

    private func installTextFallback(_ reason: String) {
        PreviewLog.stage("prepare.fallback")
        previewPreparationStatus = "fallback"
        let text = "Schema preview unavailable: \(reason)"
        if let root = quickLookView ?? (view as? ParquetQuickLookView) {
            root.showFailureText(text)
        } else if isViewLoaded {
            let label = NSTextField(wrappingLabelWithString: text)
            label.frame = view.bounds
            label.autoresizingMask = [.width, .height]
            view.addSubview(label)
        }
        preferredContentSize = RowPreviewLayout.clampedWindowSize(RowPreviewLayout.schemaOnlySize)
    }

    /// The host test calls this on the principal class after the preview is in a window.
    @objc func exerciseFilterAlignmentForTest() -> NSNumber {
        (view as? ParquetQuickLookView)?.exerciseFilterAlignmentForTest() ?? 0
    }

    @objc func exerciseFilterEditingForTest() -> NSString {
        (view as? ParquetQuickLookView)?.exerciseFilterEditingForTest() ?? "no-view"
    }

    @objc func exerciseFilterDebounceForTest() -> NSString {
        (view as? ParquetQuickLookView)?.exerciseFilterDebounceForTest() ?? "no-view"
    }

    @objc func exerciseFilterSheetForTest() -> NSString {
        (view as? ParquetQuickLookView)?.exerciseFilterSheetForTest() ?? "no-view"
    }

    @objc func exerciseFilterStandalonePanelForTest() -> NSString {
        (view as? ParquetQuickLookView)?.exerciseFilterStandalonePanelForTest() ?? "no-view"
    }

    @objc func selectStatsTabForTest() {
        (view as? ParquetQuickLookView)?.selectStatsTabForTest()
    }

    @objc func excelPlanForTest() -> NSString {
        (view as? ParquetQuickLookView)?.excelPlanForTest() ?? "failed"
    }

    @objc func exerciseInteractionsForTest() -> NSString {
        (view as? ParquetQuickLookView)?.exerciseInteractionsForTest() ?? "no-view"
    }

    @objc func beginViewExcelExportForTest() {
        (view as? ParquetQuickLookView)?.beginViewExcelExportForTest()
    }

    @objc func beginFileExcelExportForTest() {
        (view as? ParquetQuickLookView)?.beginFileExcelExportForTest()
    }

    @objc func exerciseStatsLinksForTest() -> NSString {
        (view as? ParquetQuickLookView)?.exerciseStatsLinksForTest() ?? "no-view"
    }

    @objc func exerciseUnparsedLinkForTest() -> NSString {
        (view as? ParquetQuickLookView)?.exerciseUnparsedLinkForTest() ?? "no-view"
    }

    @objc func exercisePricePercentilesForTest() -> NSString {
        (view as? ParquetQuickLookView)?.exercisePricePercentilesForTest() ?? "no-view"
    }

    @objc func exportBannerForTest() -> NSString {
        (view as? ParquetQuickLookView)?.exportBannerForTest() ?? ""
    }

    @objc func exerciseFallbackForTest() {
        installTextFallback("host test")
    }

    @objc var statsPreparationStatus: String {
        (view as? ParquetQuickLookView)?.statsStatus ?? "idle"
    }
}

private struct FilterGeometry: Equatable {
    struct Column: Equatable {
        var identifier: String
        var width: Int
        var hidden: Bool
        var minX: Int
    }

    var scrollX: Int
    var stripWidth: Int
    var columns: [Column]
}

final class SchemaNode: NSObject {
    let name: String
    let typeName: String
    let children: [SchemaNode]

    init(name: String, typeName: String, children: [SchemaNode]) {
        self.name = name
        self.typeName = typeName
        self.children = children
    }
}

final class ParquetQuickLookView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private var filePath: String?
    private var rows: [[PreviewCellValue]] = []
    private var kinds: [ColumnSortKind] = []
    private var visible: [Int] = []
    private var query = RowPreviewQuery(peekCount: RowPreviewDefaults.defaultRowCount, globalFilter: "", columnFilters: [:], sortColumn: nil, sortDirection: .off)
    private var fileRows: Int64 = 0
    private var hiddenColumns = 0
    private var rowsEnabled = false
    private var schemaRoots: [SchemaNode] = []
    private var expandDepth = 1
    private var showingRows = true
    private var didExpand = false
    private var adjustingTable = false
    private var geometryObserversInstalled = false
    private var aligningFilters = false
    private var exportBusy = false
    private var loadedColumns: [(name: String, type: String)] = []
    private var exportProgress: UnsafeMutablePointer<parquet_preview_export_progress>?
    private var exportPanel: NSPanel?
    private var exportTimer: Timer?
    private let exportQueue = DispatchQueue(label: "com.rkrug.parquetindexer.export")
    private let excelPopup = NSPopUpButton()

    private let rowsSegment = 0
    private let schemaSegment = 1
    private let statsSegment = 2
    private let statsPanel = StatsPanel()
    private let tabs = NSSegmentedControl()
    private let peekPopup = NSPopUpButton()
    private let search = PreviewSearchField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let banner = NSTextField(wrappingLabelWithString: "")
    private let filterStrip = FilterStripView()
    private var filterFields: [PreviewTextField] = []
    private let filterInputPanel = FilterInputPanel()
    private weak var filterPanelTarget: NSTextField?
    private var filterPanelBound = false
    private var filterReloadTimer: Timer?
    private var filterApplyCount = 0
    private var restoringEditor = false
    /// Host test. Forces the debounced reload path without a field editor.
    private var filterEditHold = false
    private var lastFilterGeometry: FilterGeometry?
    private let chipRow = NSStackView()
    private let clearFiltersButton = NSButton(title: "Clear filters", target: nil, action: nil)
    private var suppressFilterEdits = false
    private let distinctSheet = DistinctValueSheet()
    private var distinctColumn: Int?
    private var distinctName = ""
    private var distinctAll: [(String, Int64)] = []
    private var distinctTotal: Int?
    private var distinctEstimate = false
    private let tableScroll = NSScrollView()
    private let table = NSTableView()
    private let outlineScroll = NSScrollView()
    private let outline = NSOutlineView()
    private let content = NSView()

    private(set) var previewSize = RowPreviewLayout.schemaOnlySize

    func configure(url: URL, provider: PreviewProvider, visibleSize: CGSize) -> String {
        let settings = provider.loadSettings()
        expandDepth = settings.expandDepth
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var sourceNote: String?
        var columnCount = 1
        var schemaColumns: [PreviewProvider.ColumnInfo] = []
        var rowCountForSize = 12

        if isDirectory, let dataset = provider.readDatasetMetadata(at: url, settings: settings) {
            schemaColumns = dataset.columns
            columnCount = max(1, min(dataset.columns.count, settings.showAllColumns ? dataset.columns.count : settings.maxColumns))
            if let first = dataset.firstValidPath {
                sourceNote = "Rows from \(URL(fileURLWithPath: first).lastPathComponent)"
                filePath = first
            }
            fileRows = dataset.totalRows
        } else {
            let metadata = provider.readMetadata(at: url)
            schemaColumns = metadata.columns
            columnCount = max(1, metadata.columns.count)
            filePath = url.path
            fileRows = metadata.rowCount
            if !metadata.valid {
                filePath = nil
            }
        }

        schemaRoots = schemaTree(provider.buildDisplayRows(columns: schemaColumns.prefix(columnCount), settings: settings))
        rowsEnabled = RowPreviewLogic.decodeRowLimit(showRowPreview: settings.previewRows, requested: settings.maxPreviewRows) != nil
        query.peekCount = RowPreviewDefaults.snapRowCount(settings.maxPreviewRows)

        if rowsEnabled, let path = filePath, let limit = RowPreviewLogic.decodeRowLimit(showRowPreview: true, requested: query.peekCount) {
            PreviewLog.stage("rows.decode")
            loadRows(path: path, limit: limit, sourceNote: sourceNote)
            rowCountForSize = max(1, min(query.peekCount, rows.count))
            columnCount = max(1, kinds.count)
        } else if rowsEnabled, filePath == nil {
            banner.stringValue = "Row preview unavailable: no readable Parquet file was found. Showing the schema instead."
            showingRows = false
        }

        if !rowsEnabled {
            showingRows = false
            previewSize = RowPreviewLayout.schemaOnlySize
            PreviewLog.stage("rows.skip")
        } else {
            previewSize = RowPreviewLayout.contentSize(columns: max(kinds.count, columnCount), rows: rowCountForSize, visibleSize: visibleSize)
            if !showingRows {
                previewSize = RowPreviewLayout.contentSize(columns: columnCount, rows: 8, visibleSize: visibleSize)
            }
        }

        PreviewLog.stage("ui.build")
        buildInterface(showRowControls: rowsEnabled)
        PreviewLog.stage("ui.reload")
        reloadVisible()
        outline.reloadData()
        show(rows: showingRows && rowsEnabled)
        if rowsEnabled && showingRows {
            return "rows"
        }
        if rowsEnabled {
            return "schema"
        }
        return "schema-only"
    }

    func showFailureText(_ text: String) {
        subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: 12, y: 12, width: max(200, bounds.width - 24), height: max(40, bounds.height - 24))
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }

    private func loadRows(path: String, limit: Int, sourceNote: String?) {
        switch RowPreviewDecoder.read(path: path, maxRows: limit, maxColumns: RowPreviewDefaults.hardMaxColumns) {
        case .table(let table):
            kinds = table.columns.map { RowPreviewLogic.kind(forType: $0.typeName) }
            loadedColumns = table.columns.map { (name: $0.name, type: $0.typeName) }
            rows = table.rows.map { cells in
                cells.map { PreviewCellValue(text: $0.text, title: $0.title, truncated: $0.truncated, number: $0.number, kinds: $0.kinds) }
            }
            fileRows = table.fileRows
            hiddenColumns = table.hiddenColumns
            if self.table.tableColumns.count != table.columns.count + 1 {
                rebuildColumns(table)
            }
            banner.stringValue = ""
            banner.isHidden = true
            showingRows = true
            if let sourceNote {
                note.toolTip = sourceNote
            }
        case .failed(let message):
            banner.stringValue = "Row preview unavailable: \(message) Showing the schema instead."
            banner.isHidden = false
            showingRows = false
        }
    }

    private func rebuildColumns(_ preview: RowPreviewTable) {
        table.tableColumns.forEach { table.removeTableColumn($0) }
        filterFields.forEach { $0.removeFromSuperview() }
        filterFields = []
        let number = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("#"))
        number.title = "#"
        number.width = 52
        number.minWidth = 44
        number.resizingMask = []
        table.addTableColumn(number)
        for (index, column) in preview.columns.enumerated() {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            tableColumn.title = column.name
            tableColumn.headerToolTip = column.typeName
            tableColumn.width = RowPreviewLayout.columnWidth
            tableColumn.minWidth = 88
            tableColumn.resizingMask = .userResizingMask
            table.addTableColumn(tableColumn)
            let field = PreviewTextField()
            field.placeholderString = column.name
            field.font = NSFont.systemFont(ofSize: 11)
            field.delegate = self
            field.tag = index
            field.onRefuseInPlace = { [weak self] source in
                self?.presentFilterPanel(for: source)
            }
            filterStrip.addSubview(field)
            filterFields.append(field)
        }
        table.headerView = NSTableHeaderView()
    }

    private func buildInterface(showRowControls: Bool) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        tabs.segmentCount = 3
        tabs.setLabel("Rows", forSegment: rowsSegment)
        tabs.setLabel("Schema", forSegment: schemaSegment)
        tabs.setLabel("Stats", forSegment: statsSegment)
        tabs.setEnabled(showRowControls, forSegment: rowsSegment)
        tabs.selectedSegment = showingRows && showRowControls ? rowsSegment : schemaSegment
        tabs.target = self
        tabs.action = #selector(tabChanged)
        peekPopup.removeAllItems()
        for choice in RowPreviewDefaults.rowCountChoices {
            peekPopup.addItem(withTitle: "\(choice)")
            peekPopup.lastItem?.tag = choice
        }
        selectPeek(query.peekCount)
        peekPopup.target = self
        peekPopup.action = #selector(peekChanged)
        search.placeholderString = "Filter all columns"
        search.target = self
        search.action = #selector(filterChanged)
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = true
        search.delegate = self
        search.onRefuseInPlace = { [weak self] source in
            self?.presentFilterPanel(for: source)
        }
        note.font = NSFont.systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        banner.font = NSFont.systemFont(ofSize: 12)
        banner.textColor = .systemOrange
        banner.maximumNumberOfLines = 3
        banner.isHidden = banner.stringValue.isEmpty

        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = false
        tableScroll.borderType = .bezelBorder
        tableScroll.documentView = table
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.rowHeight = RowPreviewLayout.rowHeight
        table.style = .plain
        tableScroll.contentView.postsBoundsChangedNotifications = true
        if !geometryObserversInstalled {
            geometryObserversInstalled = true
            NotificationCenter.default.addObserver(self, selector: #selector(tableScrolled), name: NSView.boundsDidChangeNotification, object: tableScroll.contentView)
            NotificationCenter.default.addObserver(self, selector: #selector(columnGeometryChanged(_:)), name: NSTableView.columnDidResizeNotification, object: table)
            NotificationCenter.default.addObserver(self, selector: #selector(columnGeometryChanged(_:)), name: NSTableView.columnDidMoveNotification, object: table)
        }

        filterStrip.translatesAutoresizingMaskIntoConstraints = false

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Column"
        nameColumn.width = 280
        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeColumn.title = "Type"
        typeColumn.width = 220
        outline.addTableColumn(nameColumn)
        outline.addTableColumn(typeColumn)
        outline.outlineTableColumn = nameColumn
        outline.dataSource = self
        outline.delegate = self
        outline.headerView = NSTableHeaderView()
        outline.rowHeight = 20
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.hasHorizontalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.borderType = .bezelBorder

        excelPopup.removeAllItems()
        excelPopup.pullsDown = true
        excelPopup.addItem(withTitle: "Excel")
        excelPopup.addItem(withTitle: "Entire file…")
        excelPopup.lastItem?.tag = 1
        excelPopup.addItem(withTitle: "Rows view…")
        excelPopup.lastItem?.tag = 2
        excelPopup.target = self
        excelPopup.action = #selector(excelChanged)
        clearFiltersButton.target = self
        clearFiltersButton.action = #selector(clearAllFilters)
        clearFiltersButton.bezelStyle = .recessed
        clearFiltersButton.font = NSFont.systemFont(ofSize: 12)
        clearFiltersButton.isEnabled = false
        statsPanel.onActivate = { [weak self] activation in
            self?.activateStats(activation)
        }
        distinctSheet.onPick = { [weak self] value in
            self?.pickDistinctValue(value)
        }
        chipRow.orientation = .horizontal
        chipRow.spacing = 4
        chipRow.alignment = .centerY
        chipRow.isHidden = true
        let toolbar = NSStackView(views: [tabs, labeled("Rows", peekPopup), search, clearFiltersButton, excelPopup])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .centerY
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabs.isHidden = false
        peekPopup.isHidden = !showRowControls
        search.isHidden = !showRowControls

        let chrome = NSStackView()
        chrome.orientation = .vertical
        chrome.alignment = .leading
        chrome.spacing = 6
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.addArrangedSubview(toolbar)
        chrome.addArrangedSubview(banner)
        chrome.addArrangedSubview(note)
        chrome.addArrangedSubview(chipRow)
        chrome.addArrangedSubview(filterStrip)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chrome)
        addSubview(content)
        content.addSubview(tableScroll)
        content.addSubview(outlineScroll)
        content.addSubview(statsPanel)
        statsPanel.isHidden = true
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        statsPanel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = banner.stringValue.isEmpty
        if !showRowControls {
            filterStrip.isHidden = true
            note.isHidden = true
        }
        refreshExcelMenu()

        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toolbar.widthAnchor.constraint(equalTo: chrome.widthAnchor),
            note.widthAnchor.constraint(equalTo: chrome.widthAnchor),
            banner.widthAnchor.constraint(equalTo: chrome.widthAnchor),
            filterStrip.widthAnchor.constraint(equalTo: chrome.widthAnchor),
            filterStrip.heightAnchor.constraint(equalToConstant: 28),
            content.topAnchor.constraint(equalTo: chrome.bottomAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            tableScroll.topAnchor.constraint(equalTo: content.topAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outlineScroll.topAnchor.constraint(equalTo: content.topAnchor),
            outlineScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outlineScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outlineScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statsPanel.topAnchor.constraint(equalTo: content.topAnchor),
            statsPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statsPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statsPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        let stack = NSStackView(views: [label, control])
        stack.orientation = .horizontal
        stack.spacing = 4
        return stack
    }

    private func selectPeek(_ count: Int) {
        let snapped = RowPreviewDefaults.snapRowCount(count)
        for item in peekPopup.itemArray where item.tag == snapped {
            peekPopup.select(item)
            return
        }
    }

    private func show(rows wantsRows: Bool) {
        showTab(wantsRows && rowsEnabled ? rowsSegment : schemaSegment)
    }

    private func showTab(_ index: Int) {
        let rowsVisible = index == rowsSegment && rowsEnabled
        let statsVisible = index == statsSegment
        tableScroll.isHidden = !rowsVisible
        filterStrip.isHidden = !rowsVisible
        statsPanel.isHidden = !statsVisible
        outlineScroll.isHidden = rowsVisible || statsVisible
        search.isHidden = !rowsVisible
        note.isHidden = !rowsVisible
        tabs.selectedSegment = rowsVisible ? rowsSegment : (statsVisible ? statsSegment : schemaSegment)
        if rowsVisible {
            layoutFilterFields()
        }
        if statsVisible {
            statsPanel.start(path: filePath)
        }
    }

    @objc private func tabChanged() {
        showTab(tabs.selectedSegment)
    }

    var statsStatus: String { statsPanel.status }

    @objc func excelPlanForTest() -> NSString {
        guard let path = filePath else { return "failed: no file" }
        switch ExcelExporter.plan(path: path) {
        case .success(let plan):
            return "rows=\(plan.rows);columns=\(plan.columns);sheets=\(plan.sheets)" as NSString
        case .failure(let message):
            return "failed: \(message)" as NSString
        }
    }

    deinit {
        filterReloadTimer?.invalidate()
        exportTimer?.invalidate()
        exportProgress?.pointee.cancel = 1
        exportQueue.sync {}
        exportProgress?.deallocate()
        exportProgress = nil
        exportPanel?.close()
    }

    @objc func selectStatsTabForTest() {
        showTab(statsSegment)
    }

    /// Host test. Walks sort, filter, schema, and cell drawing without changing
    /// how a filter matches. Excel exports are started separately so the host
    /// can wait for them without a save panel.
    @objc func exerciseInteractionsForTest() -> NSString {
        guard table.tableColumns.count > 1 else { return "no-columns" }
        tableView(table, mouseDownInHeaderOf: table.tableColumns[0])
        let dataColumn = table.tableColumns[1]
        tableView(table, mouseDownInHeaderOf: dataColumn)
        tableView(table, mouseDownInHeaderOf: dataColumn)
        tableView(table, mouseDownInHeaderOf: dataColumn)
        let sorted = numberOfRows(in: table)

        let rowCount = numberOfRows(in: table)
        if rowCount > 0 {
            let numberColumn = table.tableColumns[0]
            let cell = NSTextFieldCell()
            var tipRect = NSRect.zero
            for row in 0..<rowCount {
                _ = tableView(table, objectValueFor: numberColumn, row: row)
                _ = tableView(table, objectValueFor: dataColumn, row: row)
                tableView(table, willDisplayCell: cell, for: numberColumn, row: row)
                tableView(table, willDisplayCell: cell, for: dataColumn, row: row)
                _ = tableView(table, toolTipFor: cell, rect: &tipRect, tableColumn: dataColumn, row: row, mouseLocation: .zero)
                _ = tableView(table, toolTipFor: cell, rect: &tipRect, tableColumn: numberColumn, row: row, mouseLocation: .zero)
            }
            _ = tableView(table, objectValueFor: dataColumn, row: rowCount + 4)
            _ = isNull(row: rowCount + 4, column: dataColumn)
        }

        search.stringValue = "alpha"
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        let filtered = numberOfRows(in: table)
        search.stringValue = ""
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nil))
        if let field = filterFields.first {
            field.stringValue = "   "
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            field.stringValue = "0"
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            field.stringValue = ""
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }

        tabs.selectedSegment = schemaSegment
        tabChanged()
        let roots = outlineView(outline, numberOfChildrenOfItem: nil)
        if roots > 0 {
            let item = outlineView(outline, child: 0, ofItem: nil)
            _ = outlineView(outline, isItemExpandable: item)
            for column in outline.tableColumns {
                _ = outlineView(outline, objectValueFor: column, byItem: item)
            }
            _ = outlineView(outline, numberOfChildrenOfItem: item)
            if outlineView(outline, numberOfChildrenOfItem: item) > 0 {
                let child = outlineView(outline, child: 0, ofItem: item)
                _ = outlineView(outline, objectValueFor: nil, byItem: child)
            }
        }
        _ = outlineView(outline, numberOfChildrenOfItem: "not-a-node")
        _ = outlineView(outline, isItemExpandable: "not-a-node")
        tabs.selectedSegment = rowsSegment
        tabChanged()

        if let ten = peekPopup.itemArray.first(where: { $0.tag == 10 }) {
            peekPopup.select(ten)
            peekChanged()
        }
        columnGeometryChanged(Notification(name: NSTableView.columnDidResizeNotification, object: table))
        dataColumn.isHidden = true
        _ = visualColumnOrder()
        dataColumn.isHidden = false
        layout()
        return "ok sorted=\(sorted) filtered=\(filtered)" as NSString
    }

    @objc func beginViewExcelExportForTest() {
        showBanner("")
        excelPopup.selectItem(withTag: 2)
        excelChanged()
    }

    @objc func beginFileExcelExportForTest() {
        showBanner("")
        excelPopup.selectItem(withTag: 1)
        excelChanged()
    }

    @objc func exportBannerForTest() -> NSString {
        banner.stringValue as NSString
    }

    @objc func exerciseStatsLinksForTest() -> NSString {
        guard statusReadyForLinks() else { return "fail stats-not-ready" }
        var report: [String] = []
        report.append("order=\(statsPanel.columnOrderForTest())")
        report.append("style-min=\(statsPanel.cellStyleForTest(columnName: "id", identifier: "min"))")
        report.append("style-mean=\(statsPanel.cellStyleForTest(columnName: "id", identifier: "mean"))")
        report.append("style-p25=\(statsPanel.cellStyleForTest(columnName: "id", identifier: "p25"))")
        report.append("style-null=\(statsPanel.cellStyleForTest(columnName: "label", identifier: "nulls"))")
        report.append("min-click=\(statsPanel.clickForTest(columnName: "id", identifier: "min"))")
        report.append("max-click=\(statsPanel.clickForTest(columnName: "id", identifier: "max"))")
        report.append("median-click=\(statsPanel.clickForTest(columnName: "id", identifier: "median"))")
        report.append("mean-click=\(statsPanel.clickForTest(columnName: "id", identifier: "mean"))")
        report.append(exerciseNullLink())
        report.append(exerciseDistinctLink())
        report.append(exercisePercentileLink(identifier: "p25", chipPrefix: "id ≥ p25"))
        report.append(exercisePercentileLink(identifier: "p75", chipPrefix: "id ≥ p75"))
        report.append(exercisePercentileLink(identifier: "p95", chipPrefix: "id ≥ p95"))
        report.append(exercisePercentileLink(identifier: "p99", chipPrefix: "id ≥ p99"))
        return report.joined(separator: " | ") as NSString
    }

    @objc func exerciseUnparsedLinkForTest() -> NSString {
        guard statusReadyForLinks() else { return "fail stats-not-ready" }
        guard statsPanel.clickForTest(columnName: "price", identifier: "type") else {
            return "fail price-marker"
        }
        let shown = numberOfRows(in: table)
        let chip = query.links.map(\.chip).joined(separator: ",")
        let noteText = note.stringValue
        let unparsedRows = visible.filter { source in
            source < rows.count && rows[source].first?.text == "nope"
        }.count
        if let fifty = peekPopup.itemArray.first(where: { $0.tag == 50 }) {
            peekPopup.select(fifty)
            peekChanged()
        }
        let kept = query.links.contains { $0.chip == "price: not int64" }
        let keptRows = numberOfRows(in: table)
        clearAllFilters()
        let cleared = query.links.isEmpty && search.stringValue.isEmpty && query.columnFilters.isEmpty
        return "chip=\(chip) rows=\(shown) unparsed=\(unparsedRows) kept=\(kept) keptRows=\(keptRows) cleared=\(cleared) tab=\(tabs.selectedSegment) note=\(noteText)" as NSString
    }

    private func statusReadyForLinks() -> Bool {
        statsPanel.status == "ready" || statsPanel.status == "partial"
    }

    private func exerciseNullLink() -> String {
        clearAllFilters()
        guard statsPanel.clickForTest(columnName: "label", identifier: "nulls") else { return "fail null-click" }
        let chip = query.links.first?.chip ?? ""
        let shown = numberOfRows(in: table)
        if let field = filterFields.first {
            field.stringValue = "2"
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        if let fifty = peekPopup.itemArray.first(where: { $0.tag == 50 }) {
            peekPopup.select(fifty)
            peekChanged()
        }
        let keptChip = query.links.contains { $0.chip == "label: is null" }
        let keptColumn = query.columnFilters[0] == "2"
        let afterPeek = numberOfRows(in: table)
        let noted = note.stringValue.contains("showing 1 of 1 nulls")
        if let linkChip = chipRow.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.title.contains("is null") }) {
            linkChip.performClick(nil)
        }
        let linkCleared = !query.links.contains { $0.kind == .isNull }
        let columnRemains = query.columnFilters[0] == "2"
        clearFiltersButton.performClick(nil)
        let allClear = query.links.isEmpty && query.columnFilters.isEmpty
        return "null chip=\(chip) rows=\(shown) kept=\(keptChip) column=\(keptColumn) after=\(afterPeek) noted=\(noted) linkCleared=\(linkCleared) columnRemains=\(columnRemains) allClear=\(allClear)"
    }

    private func exerciseDistinctLink() -> String {
        clearAllFilters()
        guard statsPanel.clickForTest(columnName: "label", identifier: "distinct") else { return "fail distinct-click" }
        let listed = distinctSheet.valuesForTest.map(\.0).joined(separator: ",")
        let distinctNote = distinctSheet.noteText
        let distinctChip = distinctName.isEmpty ? "" : RowPreviewLogic.distinctChip(column: distinctName)
        distinctSheet.pickForTest("alpha")
        let valueChip = query.links.first?.chip ?? ""
        let shown = numberOfRows(in: table)
        if let ten = peekPopup.itemArray.first(where: { $0.tag == 10 }) {
            peekPopup.select(ten)
            peekChanged()
        }
        let kept = query.links.contains { $0.chip == "label = alpha" }
        clearAllFilters()
        return "distinct values=\(listed) note=\(distinctNote) mode=\(distinctChip) value=\(valueChip) rows=\(shown) kept=\(kept)"
    }

    private func exercisePercentileLink(identifier: String, chipPrefix: String) -> String {
        clearAllFilters()
        guard statsPanel.clickForTest(columnName: "id", identifier: identifier) else { return "fail \(identifier)-click" }
        let actual = query.links.first?.chip ?? ""
        let shown = numberOfRows(in: table)
        let texts = visible.map { source -> String in
            guard source < rows.count, !rows[source].isEmpty else { return "" }
            return rows[source][0].text ?? "null"
        }.joined(separator: ",")
        if let hundred = peekPopup.itemArray.first(where: { $0.tag == 100 }) {
            peekPopup.select(hundred)
            peekChanged()
        }
        let kept = query.links.contains { $0.chip.hasPrefix(chipPrefix) }
        let still = numberOfRows(in: table)
        clearAllFilters()
        return "\(identifier) chip=\(actual) rows=\(shown) texts=\(texts) kept=\(kept) still=\(still)"
    }

    @objc func exercisePricePercentilesForTest() -> NSString {
        guard statusReadyForLinks() else { return "fail stats-not-ready" }
        selectPeekCount(100)
        var report: [String] = []
        report.append(exercisePricePercentile(identifier: "p95", expectedMin: 90, expectedRows: 5))
        if let fifty = peekPopup.itemArray.first(where: { $0.tag == 50 }) {
            peekPopup.select(fifty)
            peekChanged()
        }
        let kept = query.links.contains { $0.chip.hasPrefix("price ≥ p95") }
        let narrowed = numberOfRows(in: table)
        selectPeekCount(100)
        let restored = numberOfRows(in: table)
        report.append("kept=\(kept) narrowed=\(narrowed) restored=\(restored)")
        report.append(exercisePricePercentile(identifier: "p25", expectedMin: 24, expectedRows: 71))
        report.append("tint=\(statsPanel.rowTintedForTest(columnName: "price"))")
        report.append("type-style=\(statsPanel.cellStyleForTest(columnName: "price", identifier: "type"))")
        report.append("type=\(statsPanel.typeLabelForTest(columnName: "price"))")
        clearAllFilters()
        report.append("cleared=\(query.links.isEmpty)")
        return report.joined(separator: " | ") as NSString
    }

    private func selectPeekCount(_ count: Int) {
        guard let item = peekPopup.itemArray.first(where: { $0.tag == count }) else { return }
        peekPopup.select(item)
        peekChanged()
    }

    private func exercisePricePercentile(identifier: String, expectedMin: Int, expectedRows: Int) -> String {
        clearAllFilters()
        guard statsPanel.clickForTest(columnName: "price", identifier: identifier) else {
            return "fail \(identifier)-click"
        }
        var numbers: [Int] = []
        var unparsed = 0
        for source in visible where source < rows.count && !rows[source].isEmpty {
            let text = rows[source][0].text ?? ""
            if let value = Int(text) {
                numbers.append(value)
            } else if !text.isEmpty {
                unparsed += 1
            }
        }
        let minValue = numbers.min() ?? -1
        return "\(identifier) rows=\(numbers.count) min=\(minValue) unparsed=\(unparsed) expectMin=\(expectedMin) expectRows=\(expectedRows) chip=\(query.links.first?.chip ?? "")"
    }

    @objc private func peekChanged() {
        let selected = peekPopup.selectedItem?.tag ?? query.peekCount
        let next = RowPreviewDefaults.snapRowCount(selected)
        let global = query.globalFilter
        let columnFilters = query.columnFilters
        let links = query.links
        let sortColumn = query.sortColumn
        let sortDirection = query.sortDirection
        query.peekCount = next
        persistPeekCount(next)
        if let path = filePath {
            suppressFilterEdits = true
            loadRows(path: path, limit: next, sourceNote: nil)
            query.globalFilter = global
            query.columnFilters = columnFilters
            query.links = links
            query.sortColumn = sortColumn
            query.sortDirection = sortDirection
            query.peekCount = next
            search.stringValue = global
            for field in filterFields {
                field.stringValue = columnFilters[field.tag] ?? ""
            }
            suppressFilterEdits = false
            if !showingRows {
                show(rows: false)
            }
            refreshDistinctList()
        }
        reloadVisible()
    }

    @objc private func filterChanged() {
        query.globalFilter = editorText(search)
        applyFilterReload(immediate: !fieldIsEditing(search))
    }

    @objc private func tableScrolled() {
        alignFilterFields()
    }

    @objc private func columnGeometryChanged(_ notification: Notification) {
        guard !adjustingTable else { return }
        alignFilterFields()
    }

    override func layout() {
        super.layout()
        guard window != nil, !adjustingTable else { return }
        alignFilterFields()
    }

    private func reloadVisible() {
        let editing = editingFilterField()
        let saved = editing.map { editorText($0) }
        let range = editing?.currentEditor()?.selectedRange
        visible = RowPreviewLogic.visibleIndexes(rows: rows, kinds: kinds, query: query)
        let matched = RowPreviewLogic.matchCount(rows: rows, query: query)
        var summary = RowPreviewLogic.summary(
            shown: visible.count,
            fileRows: fileRows,
            loaded: rows.count,
            matched: matched,
            filterActive: RowPreviewLogic.filterIsActive(query) || distinctColumn != nil,
            hiddenColumns: hiddenColumns
        )
        let prefix = Int64(rows.count) < fileRows
        let linkNotes = query.links.map { RowPreviewLogic.statsLinkNote(shown: visible.count, link: $0, rowListIsPrefix: prefix) }
        if !linkNotes.isEmpty {
            summary += " " + linkNotes.joined(separator: " ")
        }
        note.stringValue = summary
        refreshChips()
        let previous = restoringEditor
        if editing != nil { restoringEditor = true }
        table.reloadData()
        widenTable()
        layoutFilterFields()
        restoringEditor = previous
        restoreEditor(editing, text: saved, range: range)
        refreshExcelMenu()
    }

    private func restoreEditor(_ field: NSTextField?, text: String?, range: NSRange?) {
        guard let field, field.currentEditor() == nil, let text, let window, window.isKeyWindow else { return }
        guard !restoringEditor else { return }
        restoringEditor = true
        field.stringValue = text
        if window.makeFirstResponder(field), let range, let editor = field.currentEditor() {
            editor.selectedRange = range
        }
        restoringEditor = false
    }

    private func applyFilterReload(immediate: Bool) {
        if immediate {
            filterReloadTimer?.invalidate()
            filterReloadTimer = nil
            filterApplyCount += 1
            reloadVisible()
            return
        }
        filterReloadTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.filterReloadTimer = nil
            self.filterApplyCount += 1
            self.reloadVisible()
        }
        filterReloadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelFilterReload() {
        filterReloadTimer?.invalidate()
        filterReloadTimer = nil
    }

    private func presentFilterPanel(for field: NSTextField) {
        if !filterPanelBound {
            filterPanelBound = true
            filterInputPanel.onChange = { [weak self] text in
                self?.applyPanelText(text)
            }
        }
        filterPanelTarget = field
        let title = field.placeholderString ?? "Filter"
        filterInputPanel.show(text: editorText(field), title: "Filter \(title)", on: window)
    }

    private func applyPanelText(_ text: String) {
        guard let field = filterPanelTarget else { return }
        suppressFilterEdits = true
        field.stringValue = text
        suppressFilterEdits = false
        writeFilter(text, from: field)
        applyFilterReload(immediate: true)
    }

    private func writeFilter(_ text: String, from field: NSTextField) {
        if field === search {
            query.globalFilter = text
            return
        }
        guard filterFields.contains(where: { $0 === field }) else { return }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query.columnFilters.removeValue(forKey: field.tag)
        } else {
            query.columnFilters[field.tag] = text
        }
    }

    @objc private func excelChanged() {
        let tag = excelPopup.selectedItem?.tag ?? 0
        excelPopup.selectItem(at: 0)
        if tag == 1 {
            exportEntireFile()
        } else if tag == 2 {
            exportActiveView()
        }
    }

    private func refreshExcelMenu() {
        excelPopup.item(at: 1)?.isEnabled = filePath != nil && !exportBusy
        excelPopup.item(at: 2)?.isEnabled = rowsEnabled && !rows.isEmpty && !loadedColumns.isEmpty && !exportBusy
    }

    private func exportEntireFile() {
        guard let path = filePath, !exportBusy else { return }
        exportBusy = true
        refreshExcelMenu()
        showBanner("Checking Excel limits…")
        exportQueue.async { [weak self] in
            let plan = ExcelExporter.plan(path: path)
            DispatchQueue.main.async { [weak self] in
                self?.continueFileExport(path: path, plan: plan)
            }
        }
    }

    private func continueFileExport(path: String, plan: Result<ExcelPlan, String>) {
        switch plan {
        case .failure(let message):
            exportBusy = false
            refreshExcelMenu()
            showBanner("Excel export unavailable: \(message)")
        case .success(let plan):
            if plan.exceedsExcelLimits {
                let alert = NSAlert()
                alert.messageText = "Excel limits"
                alert.informativeText = ExcelHandoff.limitNote(rows: plan.rows, sheets: plan.sheets, truncatedColumns: plan.truncatedColumns)
                alert.addButton(withTitle: "Export")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn {
                    exportBusy = false
                    refreshExcelMenu()
                    showBanner("Excel export cancelled.")
                    return
                }
            }
            startFileExport(path: path, plan: plan)
        }
    }

    private func startFileExport(path: String, plan: ExcelPlan) {
        let id = UUID().uuidString
        guard let staged = ExcelStaging.make(id: id) else {
            exportBusy = false
            refreshExcelMenu()
            showBanner("Excel export could not prepare a file in the preview container.")
            return
        }
        let progress = UnsafeMutablePointer<parquet_preview_export_progress>.allocate(capacity: 1)
        progress.initialize(to: parquet_preview_export_progress(rows_written: 0, rows_total: UInt64(max(plan.rows, 0)), cancel: 0))
        exportProgress = progress
        showExportPanel(total: plan.rows)
        let destination = staged.xlsx.path
        exportQueue.async { [weak self] in
            let result = ExcelExporter.exportFile(source: path, dest: destination, progress: progress)
            DispatchQueue.main.async { [weak self] in
                self?.finishFileExport(result: result, staged: staged, plan: plan, source: path)
            }
        }
    }

    private func exportActiveView() {
        guard !exportBusy, rowsEnabled, !rows.isEmpty, !loadedColumns.isEmpty else { return }
        let order = visualColumnOrder()
        guard !order.isEmpty else {
            showBanner("Excel export needs at least one visible column.")
            return
        }
        let exported = visible.map { source -> [String?] in
            guard source >= 0, source < rows.count else { return [] }
            return rows[source].map { $0.text }
        }
        guard let json = ExcelHandoff.viewJSON(columns: loadedColumns, rows: exported, order: order) else {
            showBanner("Excel export could not read the rows view.")
            return
        }
        let source = filePath ?? "rows"
        let id = UUID().uuidString
        guard let staged = ExcelStaging.make(id: id) else {
            showBanner("Excel export could not prepare a file in the preview container.")
            return
        }
        exportBusy = true
        refreshExcelMenu()
        showBanner("Writing the rows view…")
        let destination = staged.xlsx.path
        exportQueue.async { [weak self] in
            let result = ExcelExporter.exportTable(json: json, dest: destination)
            DispatchQueue.main.async { [weak self] in
                self?.finishTableExport(result: result, staged: staged, source: source)
            }
        }
    }

    private func finishFileExport(
        result: Result<Void, String>,
        staged: ExcelStaging.Staged,
        plan: ExcelPlan,
        source: String
    ) {
        closeExportPanel()
        switch result {
        case .failure(let message):
            try? FileManager.default.removeItem(at: staged.xlsx)
            exportBusy = false
            refreshExcelMenu()
            if message == "export cancelled" {
                showBanner("Excel export cancelled.")
            } else {
                showBanner("Excel export unavailable: \(message)")
            }
        case .success:
            publishExport(staged: staged, source: source, mode: "file", plan: plan)
        }
    }

    private func finishTableExport(
        result: Result<ExcelPlan, String>,
        staged: ExcelStaging.Staged,
        source: String
    ) {
        switch result {
        case .failure(let message):
            try? FileManager.default.removeItem(at: staged.xlsx)
            exportBusy = false
            refreshExcelMenu()
            showBanner("Excel export unavailable: \(message)")
        case .success(let plan):
            publishExport(staged: staged, source: source, mode: "view", plan: plan)
        }
    }

    private func publishExport(staged: ExcelStaging.Staged, source: String, mode: String, plan: ExcelPlan) {
        let request = ExcelHandoff.Request(
            id: staged.id,
            suggestedName: ExcelHandoff.suggestedName(sourcePath: source, mode: mode),
            mode: mode,
            sheets: plan.sheets,
            rows: plan.rows,
            columns: plan.columns,
            truncatedColumns: plan.truncatedColumns
        )
        do {
            try ExcelHandoff.writeRequest(request, to: staged.request)
        } catch {
            try? FileManager.default.removeItem(at: staged.xlsx)
            exportBusy = false
            refreshExcelMenu()
            showBanner("Excel export could not hand the workbook to the app.")
            return
        }
        ExcelStaging.launchHost(id: staged.id)
        exportBusy = false
        refreshExcelMenu()
        showBanner("Choose where to save the Excel file in Parquet Quick Look and Index. If that app does not come forward, open it and it will ask.")
    }

    private func visualColumnOrder() -> [Int] {
        table.tableColumns.compactMap { column in
            guard !column.isHidden else { return nil }
            let index = columnIndex(column)
            return index >= 0 ? index : nil
        }
    }

    private func showBanner(_ text: String) {
        banner.stringValue = text
        banner.isHidden = text.isEmpty
    }

    private func showExportPanel(total: Int64) {
        exportPanel?.close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 96),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Exporting Excel"
        panel.level = .floating
        let label = NSTextField(wrappingLabelWithString: progressText(written: 0, total: total))
        label.frame = NSRect(x: 16, y: 48, width: 348, height: 36)
        label.tag = 1
        let button = NSButton(title: "Cancel", target: self, action: #selector(cancelExport))
        button.frame = NSRect(x: 262, y: 12, width: 96, height: 28)
        button.bezelStyle = .rounded
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(button)
        panel.center()
        panel.orderFront(nil)
        exportPanel = panel
        exportTimer?.invalidate()
        exportTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refreshExportPanel()
        }
    }

    private func refreshExportPanel() {
        guard let progress = exportProgress, let label = exportPanel?.contentView?.viewWithTag(1) as? NSTextField else { return }
        let text = progressText(written: Int64(progress.pointee.rows_written), total: Int64(progress.pointee.rows_total))
        label.stringValue = text
        showBanner(text)
    }

    private func progressText(written: Int64, total: Int64) -> String {
        if total > 0 {
            return "Writing row \(written) of \(total)."
        }
        return "Writing rows…"
    }

    @objc private func cancelExport() {
        exportProgress?.pointee.cancel = 1
    }

    private func closeExportPanel() {
        exportTimer?.invalidate()
        exportTimer = nil
        exportPanel?.close()
        exportPanel = nil
        exportProgress?.deallocate()
        exportProgress = nil
    }

    private func widenTable() {
        guard !adjustingTable else { return }
        adjustingTable = true
        defer { adjustingTable = false }
        let width = table.tableColumns.reduce(CGFloat(0)) { $0 + $1.width }
        let needed = max(width, tableScroll.contentView.bounds.width)
        if abs(table.frame.size.width - needed) > 1 {
            var frame = table.frame
            frame.size.width = needed
            table.frame = frame
        }
    }

    private func layoutFilterFields() {
        alignFilterFields()
    }

    private func alignFilterFields() {
        guard !aligningFilters else { return }
        let geometry = filterGeometryToken()
        if geometry == lastFilterGeometry { return }
        aligningFilters = true
        let editing = editingFilterField()
        let saved = editing.map { editorText($0) }
        let range = editing?.currentEditor()?.selectedRange
        // Ending an edit assigns the field frame, which posts textDidChange.
        // Ignore that notification so a layout pass does not reload the table.
        let previous = restoringEditor
        restoringEditor = true
        FilterFieldLayout.align(table: table, strip: filterStrip, fields: filterFields)
        lastFilterGeometry = filterGeometryToken()
        if let editing, editing.currentEditor() == nil, let saved, let window, window.isKeyWindow {
            editing.stringValue = saved
            if window.makeFirstResponder(editing), let range, let editor = editing.currentEditor() {
                editor.selectedRange = range
            }
        }
        restoringEditor = previous
        aligningFilters = false
    }

    private func filterGeometryToken() -> FilterGeometry {
        FilterGeometry(
            scrollX: snap(tableScroll.contentView.bounds.origin.x),
            stripWidth: snap(filterStrip.bounds.width),
            columns: table.tableColumns.map { column in
                let index = table.column(withIdentifier: column.identifier)
                let minX = index >= 0 ? table.rect(ofColumn: index).minX : 0
                return FilterGeometry.Column(
                    identifier: column.identifier.rawValue,
                    width: snap(column.width),
                    hidden: column.isHidden,
                    minX: snap(minX)
                )
            }
        )
    }

    private func snap(_ value: CGFloat) -> Int {
        Int((value * 2).rounded())
    }

    private func editingFilterField() -> NSTextField? {
        if fieldIsEditing(search) { return search }
        return filterFields.first { fieldIsEditing($0) }
    }

    private func fieldIsEditing(_ field: NSTextField) -> Bool {
        if filterEditHold && (field === search || filterFields.contains(where: { $0 === field })) {
            return true
        }
        if field.currentEditor() != nil { return true }
        guard let editor = field.window?.firstResponder as? NSTextView else { return false }
        return (editor.delegate as AnyObject) === field
    }

    private func editorText(_ field: NSTextField) -> String {
        field.currentEditor()?.string ?? field.stringValue
    }

    /// Host test: resize a column, scroll sideways, and require the fields to
    /// keep the column rects. Returns 1 when every visible field matches.
    @objc func exerciseFilterAlignmentForTest() -> NSNumber {
        guard table.tableColumns.count > 1, !filterFields.isEmpty, window != nil else { return 0 }
        alignFilterFields()
        let column = table.tableColumns[1]
        column.width += 40
        alignFilterFields()
        guard FilterFieldLayout.matchesColumnRects(table: table, fields: filterFields) else { return 0 }
        column.width += 900
        widenTable()
        alignFilterFields()
        let clip = tableScroll.contentView
        let scrolled = NSPoint(x: clip.bounds.origin.x + 30, y: clip.bounds.origin.y)
        clip.scroll(to: scrolled)
        tableScroll.reflectScrolledClipView(clip)
        tableScrolled()
        return FilterFieldLayout.matchesColumnRects(table: table, fields: filterFields) ? 1 : 0
    }

    /// Host test. Types into the first column field in place and waits for the
    /// debounced reload. The field object must stay the same, and layout must
    /// not assign a new frame while the caret is up.
    @objc func exerciseFilterEditingForTest() -> NSString {
        guard let field = filterFields.first, let window else { return "fail no-field" }
        clearAllFilters()
        let identity = ObjectIdentifier(field)
        filterApplyCount = 0
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.05))
        layoutSubtreeIfNeeded()
        alignFilterFields()
        guard sendMouseDown(to: field) else { return "fail event" }
        let editor = field.currentEditor() != nil
        let panelShown = filterInputPanel.isShownForTest
        let key = window.isKeyWindow
        let writesBefore = FilterFieldLayout.frameWritesForTest
        if let editorView = field.currentEditor() as? NSTextView {
            let length = (editorView.string as NSString).length
            editorView.insertText("0", replacementRange: NSRange(location: length, length: 0))
        }
        layoutSubtreeIfNeeded()
        alignFilterFields()
        let writes = FilterFieldLayout.frameWritesForTest - writesBefore
        let text = editorText(field)
        let survived = text == "0" && field.currentEditor() != nil
        let immediate = filterApplyCount
        if editor {
            let deadline = Date().addingTimeInterval(0.5)
            while filterApplyCount < 1 && Date() < deadline {
                RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.02))
            }
        }
        var fallbackRows = -1
        if !editor && panelShown {
            filterInputPanel.setTextForTest("0")
            fallbackRows = numberOfRows(in: table)
        }
        let rows = numberOfRows(in: table)
        let reloads = filterApplyCount
        let same = filterFields.first.map { ObjectIdentifier($0) == identity } ?? false
        let originalWidth = table.tableColumns.count > 1 ? table.tableColumns[1].width : 0
        if table.tableColumns.count > 1 {
            table.tableColumns[1].width += 25
        }
        alignFilterFields()
        let restored = editorText(field) == "0" && field.currentEditor() != nil
        if table.tableColumns.count > 1 {
            table.tableColumns[1].width = originalWidth
            alignFilterFields()
        }
        clearAllFilters()
        return "key=\(key ? 1 : 0) editor=\(editor ? 1 : 0) panel=\(panelShown ? 1 : 0) text=\(text) survived=\(survived ? 1 : 0) immediate=\(immediate) reloads=\(reloads) rows=\(rows) fallback-rows=\(fallbackRows) same=\(same ? 1 : 0) writes=\(writes) restored=\(restored ? 1 : 0)" as NSString
    }

    /// Host test. The reload waits while a filter edit is in progress, then shows the matching row.
    @objc func exerciseFilterDebounceForTest() -> NSString {
        guard let field = filterFields.first else { return "fail no-field" }
        clearAllFilters()
        filterApplyCount = 0
        filterEditHold = true
        field.stringValue = "0"
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        let immediate = filterApplyCount
        let deadline = Date().addingTimeInterval(0.5)
        while filterApplyCount < 1 && Date() < deadline {
            RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.02))
        }
        let rows = numberOfRows(in: table)
        let reloads = filterApplyCount
        filterEditHold = false
        clearAllFilters()
        return "immediate=\(immediate) reloads=\(reloads) rows=\(rows)" as NSString
    }

    @objc func exerciseFilterSheetForTest() -> NSString {
        exerciseFilterPanel(standalone: false)
    }

    @objc func exerciseFilterStandalonePanelForTest() -> NSString {
        exerciseFilterPanel(standalone: true)
    }

    /// Host test. The column field refuses in-place editing, so the click opens
    /// a panel. `standalone` uses a floating panel instead of a sheet.
    private func exerciseFilterPanel(standalone: Bool) -> NSString {
        guard let field = filterFields.first else { return "fail no-field" }
        clearAllFilters()
        field.forceInputPanel = true
        filterInputPanel.preferStandalone = standalone
        guard sendMouseDown(to: field) else {
            field.forceInputPanel = false
            filterInputPanel.preferStandalone = false
            return "fail event"
        }
        let shown = filterInputPanel.isShownForTest
        let sheet = filterInputPanel.isSheetForTest
        let key = field.window?.isKeyWindow == true
        filterInputPanel.setTextForTest("1")
        let rows = numberOfRows(in: table)
        let text = field.stringValue
        filterInputPanel.close()
        field.forceInputPanel = false
        filterInputPanel.preferStandalone = false
        clearAllFilters()
        let clearedRows = numberOfRows(in: table)
        return "key=\(key ? 1 : 0) panel=\(shown ? 1 : 0) sheet=\(sheet ? 1 : 0) text=\(text) rows=\(rows) cleared=\(clearedRows)" as NSString
    }

    private func sendMouseDown(to field: NSTextField) -> Bool {
        guard let window else { return false }
        let point = field.convert(NSPoint(x: 8, y: 8), to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ) else { return false }
        field.mouseDown(with: event)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        guard window != nil else { return }
        PreviewLog.stage("view.window")
        if let failure = ParquetCatchException({
            self.expandSchemaIfNeeded()
            self.widenTable()
            self.layoutFilterFields()
        }) {
            PreviewLog.error("view.window \(failure.localizedDescription)")
        }
    }

    private func expandSchemaIfNeeded() {
        guard !didExpand else { return }
        didExpand = true
        expandSchema()
    }

    private func persistPeekCount(_ count: Int) {
        RowPreviewSettingsStore.write(showRowPreview: true, maxRows: count)
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ParquetPreview/settings.json")
        guard let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        object[RowPreviewDefaults.showRowPreviewKey] = true
        object[RowPreviewDefaults.legacyShowRowPreviewKey] = true
        object[RowPreviewDefaults.maxPreviewRowsKey] = count
        if let updated = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) {
            try? updated.write(to: url, options: .atomic)
        }
    }

    private func schemaTree(_ rows: [PreviewProvider.DisplayRow]) -> [SchemaNode] {
        final class MutableNode {
            let name: String
            var typeName: String
            var children: [MutableNode] = []
            init(name: String, typeName: String) {
                self.name = name
                self.typeName = typeName
            }
            func frozen() -> SchemaNode {
                SchemaNode(name: name, typeName: typeName, children: children.map { $0.frozen() })
            }
        }
        var byID: [Int: MutableNode] = [:]
        var roots: [MutableNode] = []
        for row in rows {
            let node = MutableNode(name: row.name, typeName: row.type)
            byID[row.id] = node
            if let parent = row.parentID, let parentNode = byID[parent] {
                parentNode.children.append(node)
            } else {
                roots.append(node)
            }
        }
        return roots.map { $0.frozen() }
    }

    private func expandSchema() {
        func walk(_ nodes: [SchemaNode], depth: Int) {
            guard depth < expandDepth else { return }
            for node in nodes where !node.children.isEmpty {
                outline.expandItem(node)
                walk(node.children, depth: depth + 1)
            }
        }
        walk(schemaRoots, depth: 0)
    }

    private func activateStats(_ activation: StatsActivation) {
        switch activation {
        case .link(let link):
            closeDistinctSheet()
        if let index = query.links.firstIndex(where: { sameLinkTarget($0, link) }) {
            query.links[index] = link
        } else {
            query.links.append(link)
        }
            showTab(rowsSegment)
            reloadVisible()
        case .distinct(let column, let name, let values, let total, let capped, let estimate):
            presentDistinct(column: column, name: name, values: values, total: total, capped: capped || estimate, estimate: estimate)
        }
    }

    private func sameLinkTarget(_ lhs: StatsLink, _ rhs: StatsLink) -> Bool {
        guard lhs.column == rhs.column else { return false }
        switch (lhs.kind, rhs.kind) {
        case (.unparsed, .unparsed), (.isNull, .isNull), (.nearestNumbers, .nearestNumbers):
            return true
        case (.equalsNumber(_, let leftRole), .equalsNumber(_, let rightRole)):
            return leftRole == rightRole
        case (.atLeast(let leftName, _), .atLeast(let rightName, _)):
            return leftName == rightName
        case (.equalsText(let left), .equalsText(let right)):
            return left == right
        default:
            return false
        }
    }

    private func presentDistinct(column: Int, name: String, values: [(String, Int64)], total: Int?, capped: Bool, estimate: Bool) {
        distinctColumn = column
        distinctName = name
        distinctAll = values
        distinctTotal = total
        distinctEstimate = estimate || capped
        showTab(rowsSegment)
        refreshDistinctList()
        refreshChips()
        guard let host = window else { return }
        distinctSheet.show(on: host)
    }

    private func refreshDistinctList() {
        guard distinctColumn != nil else { return }
        let shown = RowPreviewLogic.rankedDistinct(distinctAll, limit: query.peekCount)
        let link = StatsLink(
            column: distinctColumn ?? 0,
            columnName: distinctName,
            kind: .equalsText(""),
            chip: RowPreviewLogic.distinctChip(column: distinctName),
            total: distinctTotal,
            totalIsEstimate: distinctEstimate,
            noun: "distinct"
        )
        let prefix = Int64(rows.count) < fileRows
        distinctSheet.update(values: shown.map { ($0.value, $0.count) }, noteText: RowPreviewLogic.statsLinkNote(shown: shown.count, link: link, rowListIsPrefix: prefix))
    }

    private func pickDistinctValue(_ value: String) {
        let column = distinctColumn ?? 0
        let name = distinctName
        closeDistinctSheet()
        let link = StatsLink(
            column: column,
            columnName: name,
            kind: .equalsText(value),
            chip: RowPreviewLogic.valueChip(column: name, value: value),
            total: nil,
            totalIsEstimate: Int64(rows.count) < fileRows,
            noun: "rows"
        )
        query.links.removeAll { $0.column == column && $0.chip == RowPreviewLogic.distinctChip(column: name) }
        if let index = query.links.firstIndex(where: { $0.column == column && $0.kind == .equalsText(value) }) {
            query.links[index] = link
        } else {
            query.links.append(link)
        }
        showTab(rowsSegment)
        reloadVisible()
    }

    private func closeDistinctSheet() {
        distinctColumn = nil
        distinctName = ""
        distinctAll = []
        distinctTotal = nil
        distinctEstimate = false
        distinctSheet.close()
    }

    @objc private func clearChip(_ sender: NSButton) {
        let tag = sender.tag
        if tag == 0 {
            query.globalFilter = ""
            search.stringValue = ""
        } else if tag >= 1_000, tag < 2_000 {
            let index = tag - 1_000
            query.columnFilters.removeValue(forKey: index)
            suppressFilterEdits = true
            filterFields.first { $0.tag == index }?.stringValue = ""
            suppressFilterEdits = false
        } else if tag >= 2_000, tag < 3_000 {
            let index = tag - 2_000
            if query.links.indices.contains(index) {
                query.links.remove(at: index)
            }
        } else if tag == 3_000 {
            closeDistinctSheet()
        }
        reloadVisible()
    }

    @objc private func clearAllFilters() {
        query.globalFilter = ""
        query.columnFilters = [:]
        query.links = []
        suppressFilterEdits = true
        search.stringValue = ""
        for field in filterFields {
            field.stringValue = ""
        }
        suppressFilterEdits = false
        closeDistinctSheet()
        cancelFilterReload()
        filterInputPanel.close()
        reloadVisible()
    }

    private func refreshChips() {
        for view in chipRow.arrangedSubviews {
            chipRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var titles: [(String, Int)] = []
        let global = query.globalFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty {
            titles.append(("search: \(global)", 0))
        }
        for key in query.columnFilters.keys.sorted() {
            let text = query.columnFilters[key] ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let name = key >= 0 && key < loadedColumns.count ? loadedColumns[key].name : "column"
            titles.append(("\(name): \(text)", 1_000 + key))
        }
        for (index, link) in query.links.enumerated() {
            titles.append((link.chip, 2_000 + index))
        }
        if distinctColumn != nil {
            titles.append((RowPreviewLogic.distinctChip(column: distinctName), 3_000))
        }
        for (title, tag) in titles {
            let button = NSButton(title: "\(title)  ×", target: self, action: #selector(clearChip(_:)))
            button.tag = tag
            button.bezelStyle = .recessed
            button.font = NSFont.systemFont(ofSize: 11)
            button.setButtonType(.momentaryPushIn)
            chipRow.addArrangedSubview(button)
        }
        chipRow.isHidden = titles.isEmpty
        clearFiltersButton.isEnabled = !titles.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visible.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < visible.count else { return nil }
        let source = visible[row]
        guard let tableColumn, tableColumn.identifier.rawValue != "#" else {
            return "\(source + 1)"
        }
        let index = columnIndex(tableColumn)
        guard index >= 0, source < rows.count, index < rows[source].count else { return "" }
        return rows[source][index].text ?? "null"
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard let text = cell as? NSTextFieldCell else { return }
        let nullCell = isNull(row: row, column: tableColumn)
        text.textColor = nullCell ? .systemOrange : .labelColor
        let font = NSFont.systemFont(ofSize: 12)
        if nullCell, let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) as NSFont? {
            text.font = italic
        } else {
            text.font = font
        }
        text.lineBreakMode = .byTruncatingTail
    }

    func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        guard let tableColumn, tableColumn.identifier.rawValue != "#" else { return "" }
        let index = columnIndex(tableColumn)
        guard row >= 0, row < visible.count else { return "" }
        let source = visible[row]
        guard index >= 0, source < rows.count, index < rows[source].count else { return "" }
        let value = rows[source][index]
        if let title = value.title, !title.isEmpty, title != value.text {
            return title
        }
        return value.text ?? "null"
    }

    func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
        guard tableColumn.identifier.rawValue != "#" else { return }
        let index = columnIndex(tableColumn)
        guard index >= 0 else { return }
        if query.sortColumn == index {
            query.sortDirection = RowPreviewLogic.cycleDirection(query.sortDirection)
        } else {
            query.sortColumn = index
            query.sortDirection = .ascending
        }
        if query.sortDirection == .off {
            query.sortColumn = nil
        }
        updateSortIndicators()
        reloadVisible()
    }

    private func updateSortIndicators() {
        for column in table.tableColumns {
            table.setIndicatorImage(nil, in: column)
        }
        guard let sortColumn = query.sortColumn, sortColumn + 1 < table.tableColumns.count else { return }
        let name: NSImage.Name = query.sortDirection == .descending
            ? NSImage.Name("NSDescendingSortIndicator")
            : NSImage.Name("NSAscendingSortIndicator")
        if let image = NSImage(named: name), query.sortDirection != .off {
            table.setIndicatorImage(image, in: table.tableColumns[sortColumn + 1])
        }
    }

    private func columnIndex(_ column: NSTableColumn) -> Int {
        let raw = column.identifier.rawValue
        guard raw.hasPrefix("c"), let index = Int(raw.dropFirst()) else { return -1 }
        return index
    }

    private func isNull(row: Int, column: NSTableColumn?) -> Bool {
        guard let column, column.identifier.rawValue != "#" else { return false }
        let index = columnIndex(column)
        guard row >= 0, row < visible.count else { return false }
        let source = visible[row]
        guard index >= 0, source < rows.count, index < rows[source].count else { return false }
        return rows[source][index].text == nil
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? SchemaNode { return node.children.count }
        return schemaRoots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? SchemaNode { return node.children[index] }
        return schemaRoots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SchemaNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
        guard let node = item as? SchemaNode else { return nil }
        if tableColumn?.identifier.rawValue == "type" { return node.typeName }
        return node.name
    }
}

extension ParquetQuickLookView: NSTextFieldDelegate, NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard !suppressFilterEdits, !restoringEditor else { return }
        guard let field = obj.object as? NSTextField else {
            query.globalFilter = editorText(search)
            applyFilterReload(immediate: true)
            return
        }
        writeFilter(editorText(field), from: field)
        applyFilterReload(immediate: !fieldIsEditing(field))
    }
}

final class DistinctValueSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    private let table = NSTableView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private var values: [(String, Int64)] = []
    var onPick: ((String) -> Void)?

    override init() {
        super.init()
        panel.title = "Distinct values"
        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueColumn.title = "Value"
        valueColumn.width = 240
        let countColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("count"))
        countColumn.title = "Count"
        countColumn.width = 80
        table.addTableColumn(valueColumn)
        table.addTableColumn(countColumn)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(clicked)
        table.headerView = NSTableHeaderView()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        note.font = NSFont.systemFont(ofSize: 12)
        note.maximumNumberOfLines = 3
        let content = NSStackView(views: [note, scroll])
        content.orientation = .vertical
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(content)
        if let host = panel.contentView {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
        }
    }

    var noteText: String { note.stringValue }
    var valuesForTest: [(String, Int64)] { values }

    func update(values: [(String, Int64)], noteText: String) {
        self.values = values
        note.stringValue = noteText
        table.reloadData()
    }

    func show(on window: NSWindow) {
        if panel.sheetParent != nil {
            return
        }
        window.beginSheet(panel)
    }

    func close() {
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
    }

    func pickForTest(_ value: String) {
        onPick?(value)
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0, row < values.count else { return }
        onPick?(values[row].0)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        values.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < values.count else { return nil }
        if tableColumn?.identifier.rawValue == "count" {
            return "\(values[row].1)"
        }
        return values[row].0
    }
}

/// Panel that can become key even when the Quick Look preview window cannot.
final class FilterInputWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Used when a filter field cannot take the keyboard inside the preview.
final class FilterInputPanel: NSObject, NSTextFieldDelegate {
    let panel = FilterInputWindow(
        contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    private let field = NSTextField()
    var onChange: ((String) -> Void)?
    var preferStandalone = false
    private var updating = false

    override init() {
        super.init()
        panel.title = "Filter"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        field.font = NSFont.systemFont(ofSize: 13)
        field.delegate = self
        field.frame = NSRect(x: 16, y: 48, width: 328, height: 24)
        let close = NSButton(title: "Close", target: self, action: #selector(closeClicked))
        close.frame = NSRect(x: 248, y: 12, width: 96, height: 28)
        close.bezelStyle = .rounded
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
        content.addSubview(field)
        content.addSubview(close)
        panel.contentView = content
    }

    var isShownForTest: Bool { panel.isVisible || panel.sheetParent != nil }
    var isSheetForTest: Bool { panel.sheetParent != nil }

    func show(text: String, title: String, on window: NSWindow?) {
        panel.title = title
        updating = true
        field.stringValue = text
        updating = false
        if panel.sheetParent != nil || panel.isVisible {
            panel.makeFirstResponder(field)
            return
        }
        if !preferStandalone, let window, window.isKeyWindow {
            window.beginSheet(panel)
            if panel.sheetParent != nil {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.panel.sheetParent != nil else { return }
                    self.panel.makeFirstResponder(self.field)
                }
                return
            }
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func setTextForTest(_ text: String) {
        field.stringValue = text
        controlTextDidChange(Notification(name: NSText.didChangeNotification, object: field))
    }

    func close() {
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        }
        panel.orderOut(nil)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !updating else { return }
        onChange?(field.stringValue)
    }

    @objc private func closeClicked() {
        close()
    }
}

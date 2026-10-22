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

    private let rowsSegment = 0
    private let schemaSegment = 1
    private let tabs = NSSegmentedControl()
    private let peekPopup = NSPopUpButton()
    private let search = NSSearchField()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let banner = NSTextField(wrappingLabelWithString: "")
    private let filterScroll = NSScrollView()
    private let filterDocument = NSView()
    private var filterFields: [NSTextField] = []
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
            rows = table.rows.map { cells in
                cells.map { PreviewCellValue(text: $0.text, title: $0.title, truncated: $0.truncated) }
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
            let field = NSTextField()
            field.placeholderString = column.name
            field.font = NSFont.systemFont(ofSize: 11)
            field.delegate = self
            field.tag = index
            filterDocument.addSubview(field)
            filterFields.append(field)
        }
        table.headerView = NSTableHeaderView()
    }

    private func buildInterface(showRowControls: Bool) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        tabs.segmentCount = 2
        tabs.setLabel("Rows", forSegment: rowsSegment)
        tabs.setLabel("Schema", forSegment: schemaSegment)
        tabs.selectedSegment = showingRows ? rowsSegment : schemaSegment
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
        table.allowsColumnReordering = false
        table.rowHeight = RowPreviewLayout.rowHeight
        table.style = .plain
        tableScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(tableScrolled), name: NSView.boundsDidChangeNotification, object: tableScroll.contentView)

        filterScroll.hasVerticalScroller = false
        filterScroll.hasHorizontalScroller = false
        filterScroll.drawsBackground = false
        filterScroll.documentView = filterDocument
        filterDocument.frame = NSRect(x: 0, y: 0, width: 800, height: 26)

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

        let toolbar = NSStackView(views: [tabs, labeled("Rows", peekPopup), search])
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.alignment = .centerY
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabs.isHidden = !showRowControls
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
        chrome.addArrangedSubview(filterScroll)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chrome)
        addSubview(content)
        content.addSubview(tableScroll)
        content.addSubview(outlineScroll)
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        filterScroll.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        banner.isHidden = banner.stringValue.isEmpty
        if !showRowControls {
            filterScroll.isHidden = true
            note.isHidden = true
        }

        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            toolbar.widthAnchor.constraint(equalTo: chrome.widthAnchor),
            note.widthAnchor.constraint(equalTo: chrome.widthAnchor),
            banner.widthAnchor.constraint(equalTo: chrome.widthAnchor),
            filterScroll.widthAnchor.constraint(equalTo: chrome.widthAnchor),
            filterScroll.heightAnchor.constraint(equalToConstant: 28),
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
            outlineScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
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
        let rowsVisible = wantsRows && rowsEnabled
        tableScroll.isHidden = !rowsVisible
        filterScroll.isHidden = !rowsVisible
        outlineScroll.isHidden = rowsVisible
        tabs.selectedSegment = rowsVisible ? rowsSegment : schemaSegment
        if rowsVisible {
            layoutFilterFields()
        }
    }

    @objc private func tabChanged() {
        show(rows: tabs.selectedSegment == rowsSegment)
    }

    @objc private func peekChanged() {
        let selected = peekPopup.selectedItem?.tag ?? query.peekCount
        query.peekCount = RowPreviewDefaults.snapRowCount(selected)
        persistPeekCount(query.peekCount)
        if query.peekCount > rows.count, let path = filePath {
            loadRows(path: path, limit: query.peekCount, sourceNote: nil)
            if !showingRows {
                show(rows: false)
            }
        }
        reloadVisible()
    }

    @objc private func filterChanged() {
        query.globalFilter = search.stringValue
        reloadVisible()
    }

    @objc private func tableScrolled() {
        let origin = tableScroll.contentView.bounds.origin
        filterScroll.contentView.scroll(to: NSPoint(x: origin.x, y: 0))
        filterScroll.reflectScrolledClipView(filterScroll.contentView)
    }

    private func reloadVisible() {
        visible = RowPreviewLogic.visibleIndexes(rows: rows, kinds: kinds, query: query)
        let matched = RowPreviewLogic.matchCount(rows: rows, query: query)
        note.stringValue = RowPreviewLogic.summary(
            shown: visible.count,
            fileRows: fileRows,
            loaded: rows.count,
            matched: matched,
            filterActive: RowPreviewLogic.filterIsActive(query),
            hiddenColumns: hiddenColumns
        )
        table.reloadData()
        widenTable()
        layoutFilterFields()
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
        var document = filterDocument.frame
        document.size.width = max(needed, document.size.width)
        document.size.height = 26
        filterDocument.frame = document
    }

    private func layoutFilterFields() {
        var x: CGFloat = 56
        for (index, field) in filterFields.enumerated() {
            let width = index + 1 < table.tableColumns.count ? table.tableColumns[index + 1].width : RowPreviewLayout.columnWidth
            field.frame = NSRect(x: x + 2, y: 2, width: max(40, width - 6), height: 22)
            x += width
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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

extension ParquetQuickLookView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else {
            query.globalFilter = search.stringValue
            reloadVisible()
            return
        }
        if field === search {
            query.globalFilter = field.stringValue
        } else if field.tag >= 0 {
            let text = field.stringValue
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                query.columnFilters.removeValue(forKey: field.tag)
            } else {
                query.columnFilters[field.tag] = text
            }
        }
        reloadVisible()
    }
}

import AppKit

enum StatsActivation {
    case link(StatsLink)
    case distinct(column: Int, name: String, values: [(String, Int64)], total: Int?, capped: Bool, estimate: Bool)
}

/// One row per column. The scan runs off the main thread and can be cancelled
/// when the preview closes or the user leaves the tab for a different file.
final class StatsPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var status = "idle"
    private var columns: [StatsColumn] = []
    private var loadedPath: String?
    private var generation = UUID()
    private var job: StatsCancelFlag?
    private var scanPartial = false
    private let note = NSTextField(wrappingLabelWithString: "")
    private let table = StatsTableView()
    private let scroll = NSScrollView()
    var onActivate: ((StatsActivation) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    deinit {
        job?.cancel()
    }

    func start(path: String?) {
        guard let path else {
            status = "failed"
            note.stringValue = "Column stats need a readable Parquet file."
            return
        }
        if loadedPath == path, status == "ready" || status == "partial" || status == "loading" {
            return
        }
        job?.cancel()
        let flag = StatsCancelFlag()
        job = flag
        loadedPath = path
        status = "loading"
        note.stringValue = "Computing column stats…"
        columns = []
        table.reloadData()
        let token = UUID()
        generation = token
        PreviewLog.stage("stats.begin \(URL(fileURLWithPath: path).lastPathComponent)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = StatsDecoder.read(path: path, cancel: flag.pointer)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ result: Result<StatsDocument, String>) {
        switch result {
        case .failure(let message):
            status = "failed"
            note.stringValue = "Column stats unavailable: \(message)"
            PreviewLog.error("stats.failed \(message)")
        case .success(let document):
            columns = document.columns
            scanPartial = document.partial
            status = document.partial ? "partial" : "ready"
            if document.partial {
                note.stringValue = ColumnStatsFormat.partialNote(scanned: document.scannedRows, fileRows: document.fileRows)
            } else if document.columns.isEmpty {
                note.stringValue = "This file has no columns."
            } else {
                note.stringValue = "Column stats for \(document.fileRows) rows."
            }
            PreviewLog.stage(document.partial ? "stats.partial" : "stats.ready")
        }
        table.reloadData()
    }

    private func build() {
        note.font = NSFont.systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        let titles = [
            ("name", "Column", 140),
            ("type", "Type", 220),
            ("count", "Count", 70),
            ("nulls", "Nulls", 90),
            ("distinct", "Distinct", 120),
            ("min", "Min", 110),
            ("mean", "Mean", 90),
            ("median", "Median", 100),
            ("max", "Max", 110),
            ("stddev", "Stddev", 90),
            ("p25", "P25", 80),
            ("p75", "P75", 80),
            ("p95", "P95", 90),
            ("p99", "P99", 90),
            ("top", "Top values", 220)
        ]
        for (identifier, title, width) in titles {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = CGFloat(width)
            column.minWidth = 60
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(cellClicked)
        table.handCursor = { [weak self] row, column in
            self?.isClickable(row: row, column: column) ?? false
        }
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.headerView = NSTableHeaderView()
        table.style = .plain
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
        note.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(note)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            note.topAnchor.constraint(equalTo: topAnchor),
            note.leadingAnchor.constraint(equalTo: leadingAnchor),
            note.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tracking areas deliver mouse-moved events only when the window accepts them.
        window?.acceptsMouseMovedEvents = true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        columns.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < columns.count, let tableColumn else { return nil }
        let column = columns[row]
        switch tableColumn.identifier.rawValue {
        case "name": return column.name
        case "type": return column.typeLabel
        case "count": return "\(column.count)"
        case "nulls": return ColumnStatsFormat.nullLabel(nulls: column.nulls, percent: column.nullPercent)
        case "distinct": return ColumnStatsFormat.distinctLabel(distinct: column.distinct, exact: column.distinctExact)
        case "min": return column.min ?? ""
        case "max": return column.max ?? ""
        case "mean": return column.mean ?? ""
        case "median": return column.median ?? ""
        case "p95": return column.p95 ?? ""
        case "p99": return column.p99 ?? ""
        case "stddev": return column.stddev ?? ""
        case "p25": return column.p25 ?? ""
        case "p75": return column.p75 ?? ""
        case "top": return ColumnStatsFormat.topLabel(column.top.map { ($0.value, $0.count) })
        default: return ""
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = StatsTintedRow()
        view.tinted = row >= 0 && row < columns.count && columns[row].isPartial
        return view
    }

    func tableView(_ tableView: NSTableView, willDisplayCell cell: Any, for tableColumn: NSTableColumn?, row: Int) {
        guard let text = cell as? NSTextFieldCell else { return }
        text.textColor = textColor(row: row, identifier: tableColumn?.identifier.rawValue ?? "")
    }

    private func textColor(row: Int, identifier: String) -> NSColor {
        guard row >= 0, row < columns.count else { return .labelColor }
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == identifier }) else {
            return .labelColor
        }
        if activation(row: row, column: column) != nil {
            return .linkColor
        }
        return .labelColor
    }

    func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer, tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        guard row >= 0, row < columns.count, let tableColumn else { return "" }
        return tooltip(column: columns[row], identifier: tableColumn.identifier.rawValue)
    }

    @objc private func cellClicked() {
        let row = table.clickedRow
        let column = table.clickedColumn
        guard let activation = activation(row: row, column: column) else { return }
        onActivate?(activation)
    }

    func clickForTest(columnName: String, identifier: String) -> Bool {
        guard let row = columns.firstIndex(where: { $0.name == columnName }) else { return false }
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == identifier }) else { return false }
        guard let activation = activation(row: row, column: column) else { return false }
        onActivate?(activation)
        return true
    }

    private func isClickable(row: Int, column: Int) -> Bool {
        activation(row: row, column: column) != nil
    }

    private func activation(row: Int, column: Int) -> StatsActivation? {
        guard row >= 0, column >= 0, row < columns.count, column < table.tableColumns.count else { return nil }
        return activation(column: columns[row], row: row, identifier: table.tableColumns[column].identifier.rawValue)
    }

    private func activation(column: StatsColumn, row: Int, identifier: String) -> StatsActivation? {
        let name = column.name
        switch identifier {
        case "type":
            guard column.isPartial, let detected = column.detected else { return nil }
            let nice = ColumnStatsFormat.inferredTypeName(detected)
            return .link(StatsLink(
                column: row,
                columnName: name,
                kind: .unparsed(inferred: detected),
                chip: RowPreviewLogic.unparsedChip(column: name, inferredLabel: nice),
                total: Int(max(0, column.unparsed)),
                totalIsEstimate: scanPartial,
                noun: "unparsed"
            ))
        case "nulls":
            guard column.nulls > 0 else { return nil }
            return .link(StatsLink(
                column: row,
                columnName: name,
                kind: .isNull,
                chip: RowPreviewLogic.nullChip(column: name),
                total: Int(column.nulls),
                totalIsEstimate: scanPartial && column.nullsScope != "footer",
                noun: "nulls"
            ))
        case "distinct":
            guard let distinct = column.distinct, distinct > 0 else { return nil }
            let capped = column.valuesCapped || !column.distinctExact
            return .distinct(
                column: row,
                name: name,
                values: column.values.map { ($0.value, $0.count) },
                total: Int(distinct),
                capped: capped,
                estimate: scanPartial || capped
            )
        case "p25", "p75", "p95", "p99":
            guard let spec = percentileSpec(column: column, identifier: identifier) else { return nil }
            return percentileLink(column: column, row: row, name: spec.name, number: spec.number, text: spec.text, count: spec.count)
        default:
            return nil
        }
    }

    private func percentileSpec(column: StatsColumn, identifier: String) -> (name: String, number: Double?, text: String?, count: Int64?)? {
        switch identifier {
        case "p25": return ("p25", column.p25Number, column.p25, column.p25Count)
        case "p75": return ("p75", column.p75Number, column.p75, column.p75Count)
        case "p95": return ("p95", column.p95Number, column.p95, column.p95Count)
        case "p99": return ("p99", column.p99Number, column.p99, column.p99Count)
        default: return nil
        }
    }

    private func percentileLink(column: StatsColumn, row: Int, name: String, number: Double?, text: String?, count: Int64?) -> StatsActivation? {
        guard let number, let text, !text.isEmpty else { return nil }
        return .link(StatsLink(
            column: row,
            columnName: column.name,
            kind: .atLeast(name: name, value: number),
            chip: RowPreviewLogic.atLeastChip(column: column.name, name: name, displayed: text),
            total: count.map { Int($0) },
            totalIsEstimate: scanPartial || !column.percentilesExact || count == nil,
            noun: "rows"
        ))
    }

    private func tooltip(column: StatsColumn, identifier: String) -> String {
        switch identifier {
        case "type":
            return column.marker?.tooltip ?? column.typeLabel
        case "nulls" where column.nulls > 0:
            return "Show null rows"
        case "distinct" where (column.distinct ?? 0) > 0:
            return "Show distinct values"
        case "p25" where column.p25Number != nil:
            return "Show rows at or above p25"
        case "p75" where column.p75Number != nil:
            return "Show rows at or above p75"
        case "p95" where column.p95Number != nil:
            return "Show rows at or above p95"
        case "p99" where column.p99Number != nil:
            return "Show rows at or above p99"
        default:
            return ""
        }
    }

    func columnOrderForTest() -> String {
        table.tableColumns.map(\.identifier.rawValue).joined(separator: ",")
    }

    func cellStyleForTest(columnName: String, identifier: String) -> String {
        guard let row = columns.firstIndex(where: { $0.name == columnName }) else { return "missing" }
        return textColor(row: row, identifier: identifier) == .linkColor ? "link" : "text"
    }

    func rowTintedForTest(columnName: String) -> Bool {
        columns.first(where: { $0.name == columnName })?.isPartial == true
    }

    func typeLabelForTest(columnName: String) -> String {
        columns.first(where: { $0.name == columnName })?.typeLabel ?? ""
    }
}

final class StatsTintedRow: NSTableRowView {
    var tinted = false

    override func drawBackground(in dirtyRect: NSRect) {
        if tinted {
            NSColor.systemRed.withAlphaComponent(0.18).setFill()
            dirtyRect.fill()
            return
        }
        super.drawBackground(in: dirtyRect)
    }
}

final class StatsTableView: NSTableView {
    var handCursor: ((Int, Int) -> Bool)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: event)
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }

    private func updateCursor(at event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        if handCursor?(row, column) == true {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

final class StatsCancelFlag {
    let pointer: UnsafeMutablePointer<Int32>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: 0)
    }

    func cancel() {
        pointer.pointee = 1
    }

    deinit {
        pointer.deallocate()
    }
}

extension StatsActivation: Equatable {
    static func == (lhs: StatsActivation, rhs: StatsActivation) -> Bool {
        switch (lhs, rhs) {
        case (.link(let left), .link(let right)):
            return left == right
        case (.distinct(let leftColumn, let leftName, _, let leftTotal, let leftCapped, let leftEstimate),
              .distinct(let rightColumn, let rightName, _, let rightTotal, let rightCapped, let rightEstimate)):
            return leftColumn == rightColumn && leftName == rightName && leftTotal == rightTotal && leftCapped == rightCapped && leftEstimate == rightEstimate
        default:
            return false
        }
    }
}

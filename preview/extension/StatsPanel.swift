import AppKit

/// One row per column. The scan runs off the main thread and can be cancelled
/// when the preview closes or the user leaves the tab for a different file.
final class StatsPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var status = "idle"
    private var columns: [StatsColumn] = []
    private var loadedPath: String?
    private var generation = UUID()
    private var job: StatsCancelFlag?
    private let note = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()

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
            ("name", "Column", 160),
            ("type", "Type", 180),
            ("count", "Count", 70),
            ("nulls", "Nulls", 90),
            ("distinct", "Distinct", 120),
            ("min", "Min", 120),
            ("max", "Max", 120),
            ("mean", "Mean", 90),
            ("median", "Median", 90),
            ("stddev", "Stddev", 90),
            ("p25", "P25", 80),
            ("p75", "P75", 80),
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
        case "stddev": return column.stddev ?? ""
        case "p25": return column.p25 ?? ""
        case "p75": return column.p75 ?? ""
        case "top": return ColumnStatsFormat.topLabel(column.top.map { ($0.value, $0.count) })
        default: return ""
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

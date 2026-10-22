import Foundation

func runRowPreviewLogicTests() {
    assertTrue(RowPreviewDefaults.showsRowPreviewByDefault, "fork default keeps row preview on")
    assertEqual(RowPreviewLogic.decodeRowLimit(showRowPreview: false, requested: 100), nil, "toggle off must not decode")
    assertEqual(RowPreviewLogic.decodeRowLimit(showRowPreview: false, requested: 1000), nil, "toggle off ignores a large request")
    assertEqual(RowPreviewLogic.decodeRowLimit(showRowPreview: true, requested: 100), 100, "default peek is 100")
    assertEqual(RowPreviewLogic.decodeRowLimit(showRowPreview: true, requested: 10), 10, "10-row choice is accepted")
    assertEqual(RowPreviewLogic.decodeRowLimit(showRowPreview: true, requested: 50), 50, "50-row choice is accepted")
    assertEqual(RowPreviewLogic.decodeRowLimit(showRowPreview: true, requested: 500), 500, "500-row choice is accepted")
    assertEqual(RowPreviewLogic.decodeRowLimit(showRowPreview: true, requested: 1000), 1000, "1000-row choice is accepted")
    assertEqual(RowPreviewLogic.decodeRowLimit(showRowPreview: true, requested: 10_000), 1000, "row cap stays at 1000")
    assertEqual(RowPreviewDefaults.hardMaxColumns, 50, "column cap stays at 50")
    assertEqual(RowPreviewDefaults.hardMaxBytes, 32 * 1024 * 1024, "byte cap stays at 32 MiB")
    assertEqual(RowPreviewDefaults.hardMaxMillis, UInt32(2_000), "time cap stays at 2 seconds")

    let screen = CGSize(width: 1440, height: 900)
    let narrow = RowPreviewLayout.contentSize(columns: 2, rows: 3, visibleSize: screen)
    let wide = RowPreviewLayout.contentSize(columns: 50, rows: 100, visibleSize: screen)
    assertTrue(narrow.width < 800, "narrow tables stay compact")
    assertTrue(narrow.height < 500, "short tables stay compact")
    assertEqual(wide.width, screen.width - RowPreviewDefaults.screenMargin * 2, "wide tables use the visible screen width")
    assertEqual(wide.height, screen.height - RowPreviewDefaults.screenMargin * 2, "tall tables use the visible screen height")
    assertTrue(narrow.width < wide.width, "a narrow table is smaller than a wide one")

    let rows: [[PreviewCellValue]] = [
        [.value("10"), .value("2020-01-03"), .value("b")],
        [.value(nil), .value("2020-01-01"), .value("a")],
        [.value("2"), .value(nil), .value("C")],
        [.value("2.5"), .value("2020-01-02"), .value(nil)]
    ]
    let kinds: [ColumnSortKind] = [.number, .date, .text]
    var query = RowPreviewQuery(peekCount: 100, globalFilter: "", columnFilters: [:], sortColumn: 0, sortDirection: .ascending)
    let byNumber = RowPreviewLogic.visibleIndexes(rows: rows, kinds: kinds, query: query).map { rows[$0][0].text }
    assertEqual(byNumber, ["2", "2.5", "10", nil], "numbers sort ascending with nulls last")

    query.sortDirection = .descending
    let byNumberDesc = RowPreviewLogic.visibleIndexes(rows: rows, kinds: kinds, query: query).map { rows[$0][0].text }
    assertEqual(byNumberDesc, ["10", "2.5", "2", nil], "numbers sort descending with nulls last")

    query.sortColumn = 1
    query.sortDirection = .ascending
    let byDate = RowPreviewLogic.visibleIndexes(rows: rows, kinds: kinds, query: query).map { rows[$0][1].text }
    assertEqual(byDate, ["2020-01-01", "2020-01-02", "2020-01-03", nil], "dates sort ascending with nulls last")

    query.sortColumn = 2
    query.sortDirection = .ascending
    let byText = RowPreviewLogic.visibleIndexes(rows: rows, kinds: kinds, query: query).map { rows[$0][2].text }
    assertEqual(byText, ["a", "b", "C", nil], "strings sort case-insensitively with nulls last")

    query.sortDirection = .off
    query.sortColumn = nil
    query.globalFilter = "b"
    let filtered = RowPreviewLogic.visibleIndexes(rows: rows, kinds: kinds, query: query)
    assertEqual(filtered, [0], "full-text filter matches any visible cell")

    query.globalFilter = ""
    query.columnFilters = [0: "2"]
    let columnFiltered = RowPreviewLogic.visibleIndexes(rows: rows, kinds: kinds, query: query).map { rows[$0][0].text }
    assertEqual(columnFiltered, ["2", "2.5"], "per-column filter keeps matching numbers")

    query.peekCount = 1
    query.columnFilters = [:]
    query.sortColumn = 0
    query.sortDirection = .ascending
    let peeked = RowPreviewLogic.visibleIndexes(rows: rows, kinds: kinds, query: query)
    assertEqual(peeked.count, 1, "peek count limits the visible rows")
    assertEqual(rows[peeked[0]][0].text, "2", "peek keeps the first row of the current sort")
    let note = RowPreviewLogic.summary(shown: 1, fileRows: 40, loaded: 4, matched: 4, filterActive: false, hiddenColumns: 0)
    assertTrue(note.contains("Showing 1 of 40 rows."), "truncated results say how many rows are showing")

    var wideRows: [[PreviewCellValue]] = []
    var wideKinds: [ColumnSortKind] = []
    for _ in 0..<50 { wideKinds.append(.text) }
    for row in 0..<1000 {
        wideRows.append((0..<50).map { column in PreviewCellValue.value("r\(row)-c\(column)") })
    }
    let started = Date()
    query = RowPreviewQuery(peekCount: 1000, globalFilter: "r999-c49", columnFilters: [0: "r999"], sortColumn: 0, sortDirection: .descending)
    let found = RowPreviewLogic.visibleIndexes(rows: wideRows, kinds: wideKinds, query: query)
    let elapsed = Date().timeIntervalSince(started)
    assertEqual(found, [999], "sort and filter find the matching row in a 1000 by 50 table")
    assertTrue(elapsed < 1, "sort and filter stay under a second at the row cap")

    let nanWindow = RowPreviewLayout.clampedWindowSize(CGSize(width: CGFloat.nan, height: CGFloat.infinity))
    assertEqual(nanWindow, RowPreviewLayout.schemaOnlySize, "non-finite window sizes fall back")
    let tiny = RowPreviewLayout.clampedWindowSize(CGSize(width: 10, height: 10))
    assertEqual(tiny, RowPreviewLayout.minimumSize, "tiny windows clamp up")
    let huge = RowPreviewLayout.clampedWindowSize(CGSize(width: 100_000, height: 80_000))
    assertEqual(huge, RowPreviewLayout.maximumSize, "huge windows clamp down")
    let missingScreen = RowPreviewLayout.contentSize(columns: 40, rows: 100, visibleSize: CGSize(width: CGFloat.nan, height: 0))
    assertTrue(missingScreen.width >= RowPreviewLayout.minimumSize.width && missingScreen.width <= RowPreviewLayout.maximumSize.width, "a missing screen stays within width bounds")
    assertTrue(missingScreen.height >= RowPreviewLayout.minimumSize.height && missingScreen.height <= RowPreviewLayout.maximumSize.height, "a missing screen stays within height bounds")

    assertEqual(
        ColumnStatsFormat.typeLabel(storage: "string", detected: "int", parsedPercent: 98.7),
        "string → int (98.7% parsed)",
        "stringly typed columns name the detected type and the parse rate"
    )
    assertEqual(ColumnStatsFormat.typeLabel(storage: "int64", detected: nil, parsedPercent: nil), "int64", "native columns keep their storage type")
    assertEqual(ColumnStatsFormat.nullLabel(nulls: 12, percent: 4.5), "12 (4.5%)", "nulls include a percent")
    assertEqual(ColumnStatsFormat.distinctLabel(distinct: 10, exact: true), "10", "exact distinct counts stay plain")
    assertEqual(ColumnStatsFormat.distinctLabel(distinct: 2048, exact: false), "≥ 2048 (approximate)", "a capped distinct count is labelled approximate")
    assertEqual(
        ColumnStatsFormat.partialNote(scanned: 10, fileRows: 100),
        "Stats other than footer min/max/nulls are based on the first 10 of 100 rows.",
        "a partial scan says how many rows it used"
    )
    assertEqual(ColumnStatsFormat.topLabel([("alpha", 2), ("beta", 1)]), "alpha (2), beta (1)", "top values keep their counts")
}

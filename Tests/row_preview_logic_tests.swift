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
        "int64, except 1.3%",
        "an inferred string column below 100% shows the share that did not parse"
    )
    assertEqual(
        ColumnStatsFormat.typeLabel(storage: "string", detected: "decimal", parsedPercent: 97),
        "double, except 3%",
        "a whole unparsed percent is written without a decimal"
    )
    let partial = ColumnStatsFormat.inferredMarker(storage: "string", detected: "int", parsedPercent: 98.7, unparsed: 13)
    assertTrue(partial?.partial == true, "a high parse rate below 100% is a partial inference")
    assertEqual(partial?.label ?? "", "int64, except 1.3%", "the partial marker is the inferred type and the unparsed share")
    assertTrue(partial?.tooltip.contains("1.3% of non-empty values do not parse as int64") == true, "the tooltip names the unparsed share")
    assertTrue(partial?.tooltip.contains("13 values don't") == true, "the tooltip includes the unparsed count")
    assertTrue(partial?.tooltip.contains("Show values that don't parse") == true, "the partial marker offers the unparsed rows")
    let complete = ColumnStatsFormat.inferredMarker(storage: "string", detected: "decimal", parsedPercent: 100, unparsed: 0)
    assertEqual(complete?.label ?? "", "string → double (inferred)", "a complete inference keeps the normal marker")
    assertTrue(complete?.partial == false, "100% parsed is not tinted")
    assertTrue(ColumnStatsFormat.inferredMarker(storage: "string", detected: "int", parsedPercent: 90, unparsed: 10) == nil, "below the 95% threshold is not an inference")
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

    let exportID = "550E8400-E29B-41D4-A716-446655440000"
    assertTrue(ExcelHandoff.isExportID(exportID), "a UUID is an export id")
    assertTrue(!ExcelHandoff.isExportID("../etc/passwd"), "a path is not an export id")
    assertTrue(!ExcelHandoff.isExportID(exportID + ".xlsx"), "an extension is not an export id")
    let exports = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("excel-handoff-test", isDirectory: true)
    let staged = ExcelHandoff.containedFile(directory: exports, id: exportID, ext: "xlsx")
    assertEqual(staged?.lastPathComponent ?? "", "\(exportID).xlsx", "the staged file keeps the UUID name")
    assertTrue(ExcelHandoff.containedFile(directory: exports, id: "../etc/passwd", ext: "xlsx") == nil, "a non-UUID cannot leave the exports directory")
    assertTrue(ExcelHandoff.containedFile(directory: exports, id: exportID, ext: "txt") == nil, "only xlsx and json are staged")
    let exportURL = ExcelHandoff.exportURL(id: exportID)
    assertEqual(exportURL?.scheme, "parquetquicklook", "the handoff URL uses the host scheme")
    assertEqual(exportURL.flatMap(ExcelHandoff.id(from:)) ?? "", exportID, "the handoff URL round-trips the id")
    assertTrue(ExcelHandoff.id(from: URL(string: "parquetquicklook://export?id=../x")!) == nil, "a bad id is ignored")
    assertEqual(ExcelHandoff.suggestedName(sourcePath: "/tmp/snappy.parquet", mode: "file"), "snappy.xlsx", "the whole file keeps the source name")
    assertEqual(ExcelHandoff.suggestedName(sourcePath: "/tmp/snappy.parquet", mode: "view"), "snappy-rows.xlsx", "the rows view names itself apart from the whole file")
    let limit = ExcelHandoff.limitNote(rows: 2_000_000, sheets: 2, truncatedColumns: 3)
    assertTrue(limit.contains("2 sheets"), "a long file says it will use more than one sheet")
    assertTrue(limit.contains("3 columns"), "extra columns are called out before export")
    let view = ExcelHandoff.viewJSON(
        columns: [(name: "id", type: "int64"), (name: "note", type: "string")],
        rows: [["2", "=1+1"], [nil, "alpha"]],
        order: [1, 0]
    )
    let viewObject = view.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let viewColumns = viewObject?["columns"] as? [[String: String]]
    let viewRows = viewObject?["rows"] as? [[Any]]
    assertEqual(viewColumns?.first?["name"] ?? "", "note", "the rows view export follows visual column order")
    assertEqual(viewRows?.first?.first as? String ?? "", "=1+1", "the exported cell keeps the displayed text")
    let lastRow = viewRows?.last ?? []
    assertTrue(lastRow.contains { $0 is NSNull }, "a null cell stays null in the export")

    let parsedRows: [[PreviewCellValue]] = [
        [PreviewCellValue(text: "1", title: nil, truncated: false, number: 1, kinds: ["int", "decimal"])],
        [PreviewCellValue(text: "nope", title: nil, truncated: false, number: nil, kinds: [])],
        [PreviewCellValue(text: nil, title: nil, truncated: false, number: nil, kinds: [])],
        [PreviewCellValue(text: "9", title: nil, truncated: false, number: 9, kinds: ["int", "decimal"])]
    ]
    let parsedKinds: [ColumnSortKind] = [.number]
    var linked = RowPreviewQuery(peekCount: 10, globalFilter: "", columnFilters: [:], sortColumn: nil, sortDirection: .off)
    linked.links = [StatsLink(column: 0, columnName: "price", kind: .unparsed(inferred: "int"), chip: RowPreviewLogic.unparsedChip(column: "price", inferredLabel: "int64"), total: 1, totalIsEstimate: false, noun: "unparsed")]
    assertEqual(RowPreviewLogic.unparsedChip(column: "price", inferredLabel: "int64"), "price: not int64", "the unparsed chip names the inferred type")
    let unparsed = RowPreviewLogic.visibleIndexes(rows: parsedRows, kinds: parsedKinds, query: linked).map { parsedRows[$0][0].text }
    assertEqual(unparsed, ["nope"] as [String?], "the unparsed link keeps values that are not the inferred type")
    linked.links = [StatsLink(column: 0, columnName: "price", kind: .isNull, chip: RowPreviewLogic.nullChip(column: "price"), total: 1, totalIsEstimate: false, noun: "nulls")]
    assertEqual(RowPreviewLogic.nullChip(column: "price"), "price: is null", "the null chip names the column")
    let nulls = RowPreviewLogic.visibleIndexes(rows: parsedRows, kinds: parsedKinds, query: linked).map { parsedRows[$0][0].text }
    assertEqual(nulls, [nil], "the null link keeps null cells")
    linked.links = [StatsLink(column: 0, columnName: "price", kind: .equalsNumber(1, role: "min"), chip: RowPreviewLogic.boundChip(column: "price", displayed: "1", role: "min"), total: 1, totalIsEstimate: false, noun: "rows")]
    assertEqual(RowPreviewLogic.boundChip(column: "price", displayed: "1", role: "min"), "price = 1 (min)", "min and max chips name the bound")
    let mins = RowPreviewLogic.visibleIndexes(rows: parsedRows, kinds: parsedKinds, query: linked).map { parsedRows[$0][0].text }
    assertEqual(mins, ["1"] as [String?], "min compares the parsed number")
    linked.links = [StatsLink(column: 0, columnName: "price", kind: .nearestNumbers(low: 1, high: 9), chip: RowPreviewLogic.betweenChip(column: "price", low: "1", high: "9", median: "5"), total: 2, totalIsEstimate: false, noun: "rows")]
    assertEqual(RowPreviewLogic.betweenChip(column: "price", low: "1", high: "9", median: "5"), "price = 1 or 9 (median 5)", "a median between two values names both")
    let nearest = RowPreviewLogic.visibleIndexes(rows: parsedRows, kinds: parsedKinds, query: linked).map { parsedRows[$0][0].text }
    assertEqual(nearest, ["1", "9"] as [String?], "a between-median link keeps both neighbouring values")
    linked.links = [StatsLink(column: 0, columnName: "price", kind: .atLeast(name: "p95", value: 9), chip: RowPreviewLogic.atLeastChip(column: "price", name: "p95", displayed: "9"), total: 1, totalIsEstimate: false, noun: "rows")]
    assertEqual(RowPreviewLogic.atLeastChip(column: "price", name: "p95", displayed: "9"), "price ≥ p95 (9)", "p95 and p99 chips name the percentile")
    let tail = RowPreviewLogic.visibleIndexes(rows: parsedRows, kinds: parsedKinds, query: linked).map { parsedRows[$0][0].text }
    assertEqual(tail, ["9"] as [String?], "p95 keeps parsed values at or above the percentile")
    let storedNumbers: [[PreviewCellValue]] = [
        [PreviewCellValue(text: "1.234,50", title: nil, truncated: false, number: 1234.5, kinds: ["decimal"])],
        [PreviewCellValue(text: "9", title: nil, truncated: false, number: 9, kinds: ["int", "decimal"])],
        [PreviewCellValue(text: "nope", title: nil, truncated: false, number: nil, kinds: [])]
    ]
    linked.links = [StatsLink(column: 0, columnName: "amount", kind: .atLeast(name: "p25", value: 10), chip: RowPreviewLogic.atLeastChip(column: "amount", name: "p25", displayed: "10"), total: 1, totalIsEstimate: false, noun: "rows")]
    let european = RowPreviewLogic.visibleIndexes(rows: storedNumbers, kinds: parsedKinds, query: linked).map { storedNumbers[$0][0].text }
    assertEqual(european, ["1.234,50"] as [String?], "a percentile keeps the parsed number, not the stored text")
    let storedDates: [[PreviewCellValue]] = [
        [PreviewCellValue(text: "2020-01-03", title: nil, truncated: false, number: 1_578_009_600, kinds: ["date"])],
        [PreviewCellValue(text: "2020-01-01", title: nil, truncated: false, number: 1_577_836_800, kinds: ["date"])],
        [PreviewCellValue(text: "1.234,50", title: nil, truncated: false, number: 1234.5, kinds: ["decimal"])]
    ]
    linked.links = [StatsLink(column: 0, columnName: "day", kind: .atLeast(name: "p75", value: 1_578_009_600), chip: RowPreviewLogic.atLeastChip(column: "day", name: "p75", displayed: "2020-01-03"), total: 1, totalIsEstimate: false, noun: "rows")]
    let later = RowPreviewLogic.visibleIndexes(rows: storedDates, kinds: parsedKinds, query: linked).map { storedDates[$0][0].text }
    assertEqual(later, ["2020-01-03"] as [String?], "a date percentile compares epoch seconds from the parsed value")
    linked.globalFilter = "nope"
    linked.links = [StatsLink(column: 0, columnName: "price", kind: .equalsText("nope"), chip: RowPreviewLogic.valueChip(column: "price", value: "nope"), total: nil, totalIsEstimate: true, noun: "rows")]
    linked.peekCount = 1
    let combined = RowPreviewLogic.visibleIndexes(rows: parsedRows, kinds: parsedKinds, query: linked)
    assertEqual(combined, [1], "a stats link stays combined with the text filter and the row cap")
    let cappedNote = RowPreviewLogic.statsLinkNote(shown: 1, link: linked.links[0], rowListIsPrefix: true)
    assertTrue(cappedNote.contains("showing 1 rows"), "a link without a total still says how many rows are showing")
    assertTrue(cappedNote.contains("Y is an estimate"), "an estimated total says so")
    assertTrue(cappedNote.contains("first decoded rows"), "a short decode says the row list is a prefix")
    let exactNote = RowPreviewLogic.statsLinkNote(shown: 1, link: StatsLink(column: 0, columnName: "price", kind: .isNull, chip: "price: is null", total: 4, totalIsEstimate: false, noun: "nulls"), rowListIsPrefix: false)
    assertEqual(exactNote, "showing 1 of 4 nulls", "a truncated null list names X and Y")
    let ranked = RowPreviewLogic.rankedDistinct([("b", 1), ("a", 2), ("c", 2)], limit: 2).map(\.value)
    assertEqual(ranked, ["a", "c"], "distinct values sort by count, then by value, and honour the row cap")
    assertTrue(RowPreviewLogic.filterIsActive(linked), "a stats link counts as an active filter")
}

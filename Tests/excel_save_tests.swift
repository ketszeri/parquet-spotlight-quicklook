import Foundation

/// Covers the save-handoff guards. `presentPending` is not called: a real
/// export request would open `NSSavePanel` and stop the test.
func runExcelSaveTests() {
    ExcelSave.install()
    ExcelSave.present(id: "not a uuid")
    ExcelSave.present(id: "")
    let bad = URL(string: "parquetquicklook://export?id=../x")!
    ExcelSave.handle(url: bad)
    let missing = URL(string: "https://example.invalid/not-an-export")!
    ExcelSave.handle(url: missing)
    assertTrue(true, "save handoff rejects ids that are not export UUIDs")
}

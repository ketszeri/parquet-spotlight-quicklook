import AppKit

/// Moves the per-column filter fields so each one shares its column's x and width.
/// The filter text and the matching rules are left alone.
enum FilterFieldLayout {
    static func align(table: NSTableView, document: NSView, fields: [NSTextField]) {
        // The strip shows the visible columns. Column rects are converted into
        // that strip, so a bezel inset or a horizontal scroll cannot leave the
        // field on a stale x.
        let width = document.enclosingScrollView?.contentView.bounds.width ?? document.bounds.width
        let next = NSRect(x: 0, y: 0, width: max(width, 1), height: 26)
        if abs(document.frame.width - next.width) > 0.5 || abs(document.frame.height - next.height) > 0.5 || document.frame.minX != 0 {
            document.frame = next
        }
        for field in fields {
            let identifier = NSUserInterfaceItemIdentifier("c\(field.tag)")
            let index = table.column(withIdentifier: identifier)
            guard index >= 0, index < table.tableColumns.count else {
                field.isHidden = true
                continue
            }
            let column = table.tableColumns[index]
            if column.isHidden || column.width <= 0 {
                field.isHidden = true
                continue
            }
            field.isHidden = false
            let rect = table.convert(table.rect(ofColumn: index), to: document)
            field.frame = NSRect(x: rect.minX, y: 2, width: rect.width, height: 22)
        }
    }

    /// Compares field frames with column rects in window coordinates, so a
    /// horizontal scroll that only moves one of them fails the check.
    static func matchesColumnRects(table: NSTableView, fields: [NSTextField]) -> Bool {
        var sawField = false
        for field in fields {
            let identifier = NSUserInterfaceItemIdentifier("c\(field.tag)")
            let index = table.column(withIdentifier: identifier)
            guard index >= 0, index < table.tableColumns.count else { return false }
            let column = table.tableColumns[index]
            if column.isHidden || column.width <= 0 {
                if !field.isHidden { return false }
                continue
            }
            if field.isHidden { return false }
            sawField = true
            let columnRect = table.convert(table.rect(ofColumn: index), to: nil)
            let fieldRect = field.convert(field.bounds, to: nil)
            if abs(columnRect.minX - fieldRect.minX) > 0.5 || abs(columnRect.width - fieldRect.width) > 0.5 {
                return false
            }
        }
        return sawField
    }
}

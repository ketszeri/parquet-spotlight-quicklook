import AppKit

/// Moves the per-column filter fields so each one shares its column's x and width.
/// The filter text and the matching rules are left alone.
///
/// A field's frame is written only when it actually moves. Assigning the same
/// frame (or a frame that jitters by a fraction of a point) ends the shared
/// field editor, so the caret never stays and the keystroke is dropped.
enum FilterFieldLayout {
    /// Counts frame assignments. The host test uses this to prove a layout
    /// pass does not touch a field that is already aligned.
    static var frameWritesForTest = 0

    static func align(table: NSTableView, strip: NSView, fields: [NSTextField]) {
        for field in fields {
            let identifier = NSUserInterfaceItemIdentifier("c\(field.tag)")
            let index = table.column(withIdentifier: identifier)
            guard index >= 0, index < table.tableColumns.count else {
                setHidden(field, true)
                continue
            }
            let column = table.tableColumns[index]
            if column.isHidden || column.width <= 0 {
                setHidden(field, true)
                continue
            }
            setHidden(field, false)
            let rect = table.convert(table.rect(ofColumn: index), to: strip)
            let next = NSRect(x: rect.minX, y: 2, width: max(rect.width, 1), height: 22)
            guard needsFrameChange(current: field.frame, next: next) else { continue }
            frameWritesForTest += 1
            field.frame = next
        }
    }

    static func needsFrameChange(current: NSRect, next: NSRect) -> Bool {
        abs(current.minX - next.minX) > 0.5
            || abs(current.minY - next.minY) > 0.5
            || abs(current.width - next.width) > 0.5
            || abs(current.height - next.height) > 0.5
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

    private static func setHidden(_ field: NSTextField, _ hidden: Bool) {
        guard field.isHidden != hidden else { return }
        field.isHidden = hidden
    }
}

/// Clips the per-column fields. They are ordinary subviews, so a click reaches
/// the text field instead of a scroll-view document that layout keeps resetting.
final class FilterStripView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }
}

/// Starts editing in the preview window when that window can become key.
enum FilterFieldFocus {
    static func beginEditing(_ field: NSTextField) -> Bool {
        guard let window = field.window, window.canBecomeKey else { return false }
        if !window.isKeyWindow {
            window.makeKey()
        }
        guard window.isKeyWindow else { return false }
        if field.currentEditor() == nil {
            guard window.makeFirstResponder(field) else { return false }
        }
        return field.currentEditor() != nil
    }
}

/// Column filter field. The first click focuses it, including in an inactive window.
final class PreviewTextField: NSTextField {
    var forceInputPanel = false
    var onRefuseInPlace: ((NSTextField) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if forceInputPanel || !FilterFieldFocus.beginEditing(self) {
            onRefuseInPlace?(self)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) {
            super.mouseDown(with: event)
        }
    }
}

/// The search field uses the same focus rule as a column field.
final class PreviewSearchField: NSSearchField {
    var forceInputPanel = false
    var onRefuseInPlace: ((NSTextField) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if forceInputPanel || !FilterFieldFocus.beginEditing(self) {
            onRefuseInPlace?(self)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) {
            super.mouseDown(with: event)
        }
    }
}

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

    static func align<Field: NSTextField>(table: NSTableView, strip: NSView, fields: [Field]) {
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
            // Assigning a frame ends the shared field editor and the placeholder
            // comes back. Leave the editing field where it is until editing ends.
            if field.currentEditor() != nil {
                PreviewLog.stage("filter.align.skip c\(field.tag) editing")
                continue
            }
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
    static func matchesColumnRects<Field: NSTextField>(table: NSTableView, fields: [Field]) -> Bool {
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
        guard let window = field.window else {
            PreviewLog.stage("filter.focus no-window")
            return false
        }
        PreviewLog.stage("filter.focus canKey=\(window.canBecomeKey ? 1 : 0) isKey=\(window.isKeyWindow ? 1 : 0)")
        guard window.canBecomeKey else { return false }
        if !window.isKeyWindow {
            window.makeKey()
        }
        guard window.isKeyWindow else {
            PreviewLog.stage("filter.focus not-key")
            return false
        }
        if field.currentEditor() == nil {
            guard window.makeFirstResponder(field) else {
                PreviewLog.stage("filter.focus responder-refused")
                return false
            }
        }
        let editing = field.currentEditor() != nil
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        PreviewLog.stage("filter.focus editor=\(editing ? 1 : 0) responder=\(responder)")
        return editing
    }
}

/// Search field used for the global filter and for each column filter.
/// A search field keeps its text the same way the working global field does,
/// instead of a plain text field whose white background and frame edits drop it.
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

/// Picks the appearance the preview should draw with and checks for light-mode
/// colors that stay white when the window is dark.
enum PreviewAppearance {
    static func preferredName(window: NSWindow?) -> NSAppearance.Name {
        let choices: [NSAppearance.Name] = [.darkAqua, .aqua]
        if let match = window?.effectiveAppearance.bestMatch(from: choices) {
            if match == .aqua, systemIsDark { return .darkAqua }
            return match
        }
        if let match = NSApp.effectiveAppearance.bestMatch(from: choices) {
            if match == .aqua, systemIsDark { return .darkAqua }
            return match
        }
        return systemIsDark ? .darkAqua : .aqua
    }

    static var systemIsDark: Bool {
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return true
        }
        if UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" {
            return true
        }
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return (global?["AppleInterfaceStyle"] as? String) == "Dark"
    }

    static func luminance(_ color: NSColor, appearance: NSAppearance) -> CGFloat {
        var value: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            value = (0.2126 * rgb.redComponent) + (0.7152 * rgb.greenComponent) + (0.0722 * rgb.blueComponent)
        }
        return value
    }

    /// An opaque near-white color that does not change under darkAqua.
    static func isHardcodedWhite(_ color: NSColor?, appearance: NSAppearance) -> Bool {
        guard let color else { return false }
        var white = false
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            white = rgb.alphaComponent > 0.9
                && rgb.redComponent > 0.92
                && rgb.greenComponent > 0.92
                && rgb.blueComponent > 0.92
        }
        return white
    }

    static func adapt(scroll: NSScrollView, table: NSTableView) {
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        table.backgroundColor = .textBackgroundColor
        table.usesAlternatingRowBackgroundColors = true
        table.gridColor = .separatorColor
    }

    static func adaptSearchField(_ field: NSSearchField) {
        field.textColor = .controlTextColor
        field.drawsBackground = false
    }

    static func isCancelKey(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "."
    }
}

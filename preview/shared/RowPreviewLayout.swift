import CoreGraphics
import Foundation

/// Preview window size from the visible screen and the table shape.
/// Quick Look does not tell the extension which screen it will use. Callers
/// pass the visible size of the screen that owns the focused window, which is
/// Finder's screen when the user presses Space.
enum RowPreviewLayout {
    static let rowHeight: CGFloat = 22
    static let columnWidth: CGFloat = 148
    static let chromeHeight: CGFloat = 188
    static let minimumSize = CGSize(width: 420, height: 280)
    /// Schema-only preview keeps the original fixed window.
    static let schemaOnlySize = CGSize(width: 1200, height: 780)

    static func contentSize(columns: Int, rows: Int, visibleSize: CGSize) -> CGSize {
        let margin = RowPreviewDefaults.screenMargin
        let availableWidth = max(minimumSize.width, visibleSize.width - margin * 2)
        let availableHeight = max(minimumSize.height, visibleSize.height - margin * 2)
        let columnCount = max(columns, 1)
        let rowCount = max(rows, 1)
        let wantedWidth = 72 + CGFloat(columnCount) * columnWidth
        let wantedHeight = chromeHeight + CGFloat(rowCount) * rowHeight
        return CGSize(
            width: min(availableWidth, max(minimumSize.width, wantedWidth)),
            height: min(availableHeight, max(minimumSize.height, wantedHeight))
        )
    }
}

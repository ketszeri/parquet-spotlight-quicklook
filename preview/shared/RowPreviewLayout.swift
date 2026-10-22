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
    static let maximumSize = CGSize(width: 4096, height: 4096)
    /// Used when the extension cannot see a screen, or the size is not a real display.
    static let fallbackVisibleSize = CGSize(width: 1280, height: 800)
    /// Schema-only preview keeps the original fixed window.
    static let schemaOnlySize = CGSize(width: 1200, height: 780)

    static func clampedVisibleSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 320, size.height >= 240,
              size.width <= 10_000, size.height <= 10_000 else {
            return fallbackVisibleSize
        }
        return size
    }

    static func clampedWindowSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite else {
            return schemaOnlySize
        }
        return CGSize(
            width: min(maximumSize.width, max(minimumSize.width, size.width)),
            height: min(maximumSize.height, max(minimumSize.height, size.height))
        )
    }

    static func contentSize(columns: Int, rows: Int, visibleSize: CGSize) -> CGSize {
        let visible = clampedVisibleSize(visibleSize)
        let margin = RowPreviewDefaults.screenMargin
        let availableWidth = max(minimumSize.width, visible.width - margin * 2)
        let availableHeight = max(minimumSize.height, visible.height - margin * 2)
        let columnCount = max(columns, 1)
        let rowCount = max(rows, 1)
        let wantedWidth = 72 + CGFloat(columnCount) * columnWidth
        let wantedHeight = chromeHeight + CGFloat(rowCount) * rowHeight
        return clampedWindowSize(CGSize(
            width: min(availableWidth, max(minimumSize.width, wantedWidth)),
            height: min(availableHeight, max(minimumSize.height, wantedHeight))
        ))
    }
}

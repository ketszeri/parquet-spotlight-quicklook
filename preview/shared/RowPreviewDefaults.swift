import Foundation

/// Row-preview policy shared by the host app, the Quick Look extension, and tests.
///
/// `showsRowPreviewByDefault` is the single switch for the fork versus upstream.
/// This fork ships `true`, so Space shows rows until the user turns them off.
/// Upstream should change this constant to `false` before merging, so existing
/// users keep the schema-only preview until they opt in.
enum RowPreviewDefaults {
    static let showsRowPreviewByDefault = true

    /// App Group suite. A Developer ID signature can share this with the
    /// sandboxed extension. Ad-hoc builds also mirror the same keys into the
    /// extension container's `settings.json`, which is the file the sandbox
    /// can read when the group container is not available.
    static let appGroupID = "group.com.rkrug.parquetindexer"
    static let showRowPreviewKey = "showRowPreview"
    static let legacyShowRowPreviewKey = "previewRows"
    static let maxPreviewRowsKey = "maxPreviewRows"

    static let rowCountChoices = [10, 50, 100, 500, 1000]
    static let defaultRowCount = 100
    static let hardMaxRows = 1000
    static let hardMaxColumns = 50
    static let hardMaxBytes: UInt64 = 32 * 1024 * 1024
    static let hardMaxMillis: UInt32 = 2_000
    static let screenMargin: CGFloat = 48

    static func snapRowCount(_ value: Int) -> Int {
        if rowCountChoices.contains(value) {
            return value
        }
        let capped = min(max(value, 1), hardMaxRows)
        return rowCountChoices.min(by: { abs($0 - capped) < abs($1 - capped) }) ?? defaultRowCount
    }
}

enum RowPreviewSettingsStore {
    static func write(showRowPreview: Bool, maxRows: Int) {
        guard let defaults = UserDefaults(suiteName: RowPreviewDefaults.appGroupID) else { return }
        defaults.set(showRowPreview, forKey: RowPreviewDefaults.showRowPreviewKey)
        defaults.set(RowPreviewDefaults.snapRowCount(maxRows), forKey: RowPreviewDefaults.maxPreviewRowsKey)
    }

    /// `nil` when this suite has never stored the toggle.
    static func readShowRowPreview(_ defaults: UserDefaults?) -> Bool? {
        guard let defaults else { return nil }
        if defaults.object(forKey: RowPreviewDefaults.showRowPreviewKey) != nil {
            return defaults.bool(forKey: RowPreviewDefaults.showRowPreviewKey)
        }
        if defaults.object(forKey: RowPreviewDefaults.legacyShowRowPreviewKey) != nil {
            return defaults.bool(forKey: RowPreviewDefaults.legacyShowRowPreviewKey)
        }
        return nil
    }

    static func readMaxRows(_ defaults: UserDefaults?) -> Int? {
        guard let defaults, defaults.object(forKey: RowPreviewDefaults.maxPreviewRowsKey) != nil else {
            return nil
        }
        return RowPreviewDefaults.snapRowCount(defaults.integer(forKey: RowPreviewDefaults.maxPreviewRowsKey))
    }
}

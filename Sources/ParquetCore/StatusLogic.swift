import Foundation

public protocol ParquetSystemAccess {
    func fileExists(atPath path: String) -> Bool
    func commandOutput(_ launchPath: String, _ arguments: [String]) -> String?
}

public struct ParquetStatusSnapshot {
    public let importerInstalled: Bool
    public let appInstalledInApplications: Bool
    public let quickLookBundlePresent: Bool

    public init(importerInstalled: Bool, appInstalledInApplications: Bool, quickLookBundlePresent: Bool) {
        self.importerInstalled = importerInstalled
        self.appInstalledInApplications = appInstalledInApplications
        self.quickLookBundlePresent = quickLookBundlePresent
    }
}

public struct ParquetStatusEvaluator {
    public let userImporterPath: String
    public let systemImporterPath: String
    public let appCandidatePaths: [String]
    public let quickLookAppexNames: [String]
    public let homeDirectory: String

    public init(
        userImporterPath: String,
        systemImporterPath: String,
        appCandidatePaths: [String],
        quickLookAppexNames: [String],
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.userImporterPath = userImporterPath
        self.systemImporterPath = systemImporterPath
        self.appCandidatePaths = appCandidatePaths
        self.quickLookAppexNames = quickLookAppexNames
        self.homeDirectory = homeDirectory
    }

    public func evaluate(using system: ParquetSystemAccess) -> ParquetStatusSnapshot {
        let appInstalled = appCandidatePaths.contains { candidate in
            system.fileExists(atPath: candidate) && isAppInApplications(candidate)
        }
        let quickLookPresent = appCandidatePaths.contains { candidate in
            hasEmbeddedQuickLookExtension(in: candidate, using: system)
        }
        let importerPresentOnDisk =
            system.fileExists(atPath: userImporterPath) || system.fileExists(atPath: systemImporterPath)
        let importerRegistered = isImporterRegistered(using: system)

        return ParquetStatusSnapshot(
            importerInstalled: importerPresentOnDisk || importerRegistered,
            appInstalledInApplications: appInstalled,
            quickLookBundlePresent: quickLookPresent
        )
    }

    public func isImporterRegistered(using system: ParquetSystemAccess) -> Bool {
        guard let out = system.commandOutput("/usr/bin/mdimport", ["-L"]) else {
            return false
        }
        return out.contains("Parquet.mdimporter")
    }

    public func isAppInApplications(_ appPath: String) -> Bool {
        let resolved = (appPath as NSString).resolvingSymlinksInPath
        let userApplications = (homeDirectory as NSString).appendingPathComponent("Applications") + "/"
        return resolved.hasPrefix("/Applications/") || resolved.hasPrefix(userApplications)
    }

    public func hasEmbeddedQuickLookExtension(in appPath: String, using system: ParquetSystemAccess) -> Bool {
        for appexName in quickLookAppexNames {
            let appexPath = (appPath as NSString).appendingPathComponent("Contents/PlugIns/\(appexName)")
            if system.fileExists(atPath: appexPath) {
                return true
            }
        }
        return false
    }
}

public enum ImporterInstallAction: Equatable {
    case install
    case replace
    case keep
}

public enum ImporterVersionLogic {
    /// Install when nothing is on disk. Replace when the installed importer is
    /// older. Keep an equal or newer install. `CFBundleVersion` decides when
    /// both sides have one; otherwise the short version is compared and a
    /// `-ketszeri.N` suffix is kept, because `ParquetSemVer` strips it.
    public static func action(installedShort: String?, installedBuild: Int?, bundledShort: String?, bundledBuild: Int?) -> ImporterInstallAction {
        let bundled = normalize(bundledShort)
        if bundled.isEmpty || bundled == "unknown" {
            return .keep
        }
        let installed = normalize(installedShort)
        if installed.isEmpty || installed == "unknown" {
            return .install
        }
        if let installedBuild, let bundledBuild, installedBuild != bundledBuild {
            return bundledBuild > installedBuild ? .replace : .keep
        }
        let order = compareShort(bundled, installed)
        if order == .orderedDescending {
            return .replace
        }
        return .keep
    }

    public static func compareShort(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let (leftVersion, leftSuffix) = splitRelease(lhs)
        let (rightVersion, rightSuffix) = splitRelease(rhs)
        if let left = ParquetSemVer(looseVersion: leftVersion), let right = ParquetSemVer(looseVersion: rightVersion), left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        if leftSuffix != rightSuffix {
            return leftSuffix < rightSuffix ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func normalize(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func splitRelease(_ value: String) -> (String, Int) {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("v") || raw.hasPrefix("V") {
            raw.removeFirst()
        }
        let parts = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let version = String(parts.first ?? "")
        let suffix = parts.count > 1 ? suffixNumber(String(parts[1])) : 0
        return (version, suffix)
    }

    private static func suffixNumber(_ prerelease: String) -> Int {
        guard let last = prerelease.split(separator: ".").last, let number = Int(last) else {
            return 0
        }
        return number
    }
}

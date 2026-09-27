import Foundation
import SystemPackage

/// Finds the index stores Xcode keeps for a project in its own DerivedData, so a `--skip-build` scan can
/// use the index Xcode already maintains instead of requiring lethen's build.
///
/// Xcode writes `info.plist` into each DerivedData directory with the `WorkspacePath` it belongs to.
/// Several directories can match one project, for example after Xcode was moved; the store written most
/// recently comes first.
public struct XcodeDerivedDataLocator {
    let root: FilePath

    public init(root: FilePath = Self.defaultRoot) {
        self.root = root
    }

    /// Xcode's custom DerivedData location when one is set in its preferences, otherwise the default.
    public static var defaultRoot: FilePath {
        if let custom = UserDefaults(suiteName: "com.apple.dt.Xcode")?.string(forKey: "IDECustomDerivedDataLocation"),
           custom.hasPrefix("/")
        {
            return FilePath(custom)
        }

        return FilePath(NSHomeDirectory()).appending("Library/Developer/Xcode/DerivedData")
    }

    /// Index stores for the project or workspace at `projectPath`, most recently written first.
    public func indexStores(for projectPath: FilePath) -> [FilePath] {
        let project = Self.resolved(projectPath)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.string) else { return [] }

        let matches: [(store: FilePath, date: Date)] = entries.compactMap { entry in
            let directory = root.appending(entry)
            guard let workspace = Self.workspacePath(in: directory), Self.resolved(workspace) == project else { return nil }

            return ["Index.noindex/DataStore", "Index/DataStore"]
                .map { directory.appending($0) }
                .first { FileManager.default.fileExists(atPath: $0.string) }
                .map { ($0, Self.lastWritten($0)) }
        }

        return matches.sorted { $0.date > $1.date }.map(\.store)
    }

    // MARK: - Private

    private static func workspacePath(in directory: FilePath) -> FilePath? {
        guard let data = FileManager.default.contents(atPath: directory.appending("info.plist").string),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = plist["WorkspacePath"] as? String
        else { return nil }

        return FilePath(path)
    }

    /// When units were last added: the newest modification date of the store's `units` directories.
    public static func lastWritten(_ store: FilePath) -> Date {
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: store.string)) ?? []
        return versions
            .compactMap { modificationDate(store.appending($0).appending("units")) }
            .max() ?? .distantPast
    }

    private static func modificationDate(_ path: FilePath) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.string))?[.modificationDate] as? Date
    }

    private static func resolved(_ path: FilePath) -> FilePath {
        FilePath(URL(fileURLWithPath: path.lexicallyNormalized().string).resolvingSymlinksInPath().path)
    }
}

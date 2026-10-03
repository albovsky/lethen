import Foundation
import SourceGraph
import SystemPackage

/// Whether anything an earlier build depends on changed since it started. A build's index units describe the files
/// as the build read them, so a project whose tracked files are all older than the build's start can reuse them.
///
/// Only files that can change what a scan reports are tracked, by extension: the sources a build compiles, the files
/// that shape how it compiles them, and the ones Lethen reads itself. Anything else, such as localized strings, asset
/// catalogs or a script's generated resources, is rewritten by builds without changing a scan's result, so a project
/// whose build phases touch them can still reuse its build.
public enum XcodeBuildInputs {
    /// Sources a build compiles. They may be newer than the build's start, as long as they predate its completion: the
    /// build can have written them, and the index collector checks each against its own unit.
    private static let compiledExtensions: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp", "cxx"]
    /// Files that decide how sources are compiled, which the build can read without compiling them.
    private static let buildShapingExtensions: Set<String> = [
        "h", "hh", "hpp", "hxx", "pch", "modulemap", "def", "inc", "inl", "ipp", "tpp", "tcc", "xcconfig", "xcscheme", "pbxproj", "xcworkspacedata", "entitlements",
    ]
    private static let buildShapingNames: Set<String> = ["Package.swift", "Package.resolved"]
    /// Files Lethen reads itself while scanning.
    private static let readExtensions: Set<String> = ["plist", "xib", "storyboard", "xcdatamodel", "xcdatamodeld", "xcmappingmodel"]
    /// Directories whose contents are the file, so everything inside is tracked.
    private static let packageExtensions: Set<String> = ["xcdatamodel", "xcdatamodeld", "xcmappingmodel"]
    private static let skippedDirectories: Set<String> = [".git", ".build"]

    /// Whether a file at `path` can change what a scan reports.
    public static func isTracked(_ path: FilePath) -> Bool {
        guard let name = path.lastComponent?.string else { return false }

        let pathExtension = path.extension?.lowercased() ?? ""
        return compiledExtensions.contains(pathExtension) || buildShapingExtensions.contains(pathExtension)
            || readExtensions.contains(pathExtension) || buildShapingNames.contains(name)
    }

    /// The directories to walk for tracked files, and the files to track whatever they are called, for a scan of
    /// `project`: its source root and the directories it declares, and every file its targets and declarations name.
    /// Declared files are tracked themselves, inside the roots or not: the walk does not follow symlinks, so a file
    /// behind a symlinked directory, or outside every root like an external `.xcconfig`, is not reached by it. `nil`
    /// when a target's files cannot be identified.
    public static func scanInputs(of project: XcodeProjectlike) -> (roots: [FilePath], files: Set<FilePath>)? {
        guard (try? project.targets.forEach { try $0.identifyFiles() }) != nil else { return nil }

        var roots: [FilePath] = []
        for root in ([project.sourceRoot] + project.projectSourceRoots).map({ $0.lexicallyNormalized() }) where !roots.contains(root) {
            roots.append(root)
        }

        let kinds = ProjectFileKind.allCases
        let files = project.targets.flatMapSet { target in kinds.flatMapSet { target.files(kind: $0) } }.union(project.declaredInputFiles)
        return (roots, files)
    }

    /// The tracked files under `roots`, and `files`, which are tracked whatever they are called. Written when a build
    /// starts so that a file added, removed or renamed afterwards shows as a difference. A root that cannot be
    /// enumerated contributes what could be read; `firstChange` reports it.
    public static func trackedPaths(roots: [FilePath], files: Set<FilePath>) -> Set<FilePath> {
        Set(walk(roots: roots, files: files).entries.map(\.path))
    }

    /// The first tracked path under `roots`, or in `files`, that changed after a build that ran from `started` to
    /// `completed`, or `nil` when none did. A compiled source may be newer than `started` as long as it predates
    /// `completed`; every other tracked file must predate `started`. `recorded` is `trackedPaths` as it was when the
    /// build started, so a file added, removed or renamed since is a change, which directory times, that builds
    /// rewrite, cannot tell. A path that cannot be read counts as changed, as does a listed file that was there when the build started and is gone, a root that does not exist or
    /// cannot be enumerated, and so does a file whose time equals the limit, since file times are coarse.
    ///
    /// Version control and build directories, `.DS_Store`, and the per-user state in `xcuserdata` are skipped, except
    /// for the schemes in it, which choose what a build compiles. A root that is a symbolic link is walked as its
    /// target, but links under a root are not followed; a listed file is read through them.
    public static func firstChange(
        roots: [FilePath],
        files: Set<FilePath>,
        recorded: Set<FilePath>,
        started: Date,
        completed: Date
    ) -> FilePath? {
        let found = walk(roots: roots, files: files)
        if let failure = found.failure { return failure }

        for (path, date) in found.entries.sorted(by: { $0.path.string < $1.path.string }) {
            let limit = compiledExtensions.contains(path.extension?.lowercased() ?? "") ? completed : started
            guard let date, date < limit else { return path }
        }

        let current = Set(found.entries.map(\.path))
        return current.symmetricDifference(recorded).min { $0.string < $1.string }
    }

    // MARK: - Private

    private struct Walk {
        var entries: [(path: FilePath, date: Date?)] = []
        var failure: FilePath?
    }

    private static func walk(roots: [FilePath], files: Set<FilePath>) -> Walk {
        var found = Walk()
        var seen: Set<FilePath> = []
        for root in roots {
            walk(root: root, into: &found, seen: &seen)
        }

        for file in files.sorted(by: { $0.string < $1.string }) {
            // A listed file's time is the one of the file a symbolic link leads to, not of the link, and it replaces
            // the time of the same file found in a root.
            let resolved = FilePath(file.url.resolvingSymlinksInPath().path)
            let date = modificationDate(of: resolved)
            // A listed file that does not exist, such as a generated `.xcconfig` that is not checked in, is absent from
            // the list as well; it is a change only once it appears, or if it was there when the build started.
            if seen.insert(file).inserted {
                if date != nil { found.entries.append((file, date)) }
            } else if let index = found.entries.firstIndex(where: { $0.path == file }) {
                found.entries[index].date = date
            }
        }

        return found
    }

    private static func walk(root: FilePath, into found: inout Walk, seen: inout Set<FilePath>) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        var unreadable: FilePath?
        // A root that is itself a symbolic link is walked as its target, which the enumerator would not enter.
        let target = FilePath(root.url.resolvingSymlinksInPath().path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.string, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: target.url,
                  includingPropertiesForKeys: keys,
                  options: [],
                  errorHandler: { url, _ in
                      unreadable = FilePath(url.path)
                      return false
                  }
              )
        else {
            found.failure = found.failure ?? root
            return
        }

        // The enumerator reports paths with symbolic links resolved, such as /private/var for /var; the names are
        // appended to the root as it was given instead.
        var components: [String] = []
        for case let url as URL in enumerator {
            components.removeSubrange(min(enumerator.level - 1, components.count)...)
            components.append(url.lastPathComponent)
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true, values?.isSymbolicLink != true {
                if skippedDirectories.contains(name) { enumerator.skipDescendants() }

                continue
            }

            if name == ".DS_Store" { continue }

            let path = components.reduce(root) { $0.appending($1) }
            guard isTracked(path, below: components.dropLast()) else { continue }

            if seen.insert(path).inserted {
                found.entries.append((path, values?.contentModificationDate))
            }
        }

        if let unreadable { found.failure = found.failure ?? unreadable }
    }

    /// Whether the file reached through `parents` is tracked there: inside a package directory everything is, and
    /// inside `xcuserdata`, the user's own state, only the schemes are.
    private static func isTracked(_ path: FilePath, below parents: ArraySlice<String>) -> Bool {
        if parents.contains("xcuserdata") { return path.extension == "xcscheme" }
        if parents.contains(where: { packageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) { return true }

        return isTracked(path)
    }

    private static func modificationDate(of path: FilePath) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.string) else { return nil }

        return attributes[.modificationDate] as? Date
    }
}

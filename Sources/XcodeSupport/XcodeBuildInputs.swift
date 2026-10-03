import Foundation
import SystemPackage

/// Whether anything an earlier build depends on changed since it started. A build's index units describe the files
/// as the build read them, so a project whose files are all older than the build's start can reuse them.
public enum XcodeBuildInputs {
    private static let compiledExtensions: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp", "cxx"]
    private static let skippedDirectories: Set<String> = [".git", ".build", "xcuserdata"]
    private static let skippedFiles: Set<String> = [".DS_Store"]

    /// The first path under `roots`, or in `files`, that changed after a build that ran from `started` to `completed`,
    /// or `nil` when none did. Any directory or file that is not a compiled source must predate `started`, whether
    /// it is found in a root or listed: a directory changes when an entry is added, removed or renamed, and every
    /// other file, such as a project file, a build setting file or a header, can change what the build compiles
    /// without the build rewriting it. A compiled source may be newer than `started` as long as it predates
    /// `completed`; the build can have written it, and the index collector checks each such file against its own
    /// unit. A path that cannot be read counts as changed, as does a root that does not exist or cannot be
    /// enumerated, and so does one whose time equals the limit, since file times are coarse.
    ///
    /// Version control and build directories, `.DS_Store`, and the per-user state in `xcuserdata` are skipped, except
    /// for the schemes in it, which choose what a build compiles. A root that is a symbolic link is walked as its target, but links under a root are not followed; a listed file is read through them.
    public static func firstChange(roots: [FilePath], files: Set<FilePath>, started: Date, completed: Date) -> FilePath? {
        for root in roots {
            if let change = firstChange(under: root, started: started, completed: completed) {
                return change
            }
        }

        for file in files.sorted() {
            let limit = compiledExtensions.contains(file.extension?.lowercased() ?? "") ? completed : started
            // A listed file's time is the one of the file a symbolic link leads to, not of the link.
            let resolved = FilePath(file.url.resolvingSymlinksInPath().path)
            guard let date = modificationDate(of: resolved), date < limit else { return file }
        }

        return nil
    }

    private static func firstChange(under root: FilePath, started: Date, completed: Date) -> FilePath? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        var unreadable: FilePath?
        // A root that is itself a symbolic link is walked as its target, which the enumerator would not enter.
        let target = FilePath(root.url.resolvingSymlinksInPath().path)
        let enumerator = FileManager.default.enumerator(
            at: target.url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, _ in
                unreadable = FilePath(url.path)
                return false
            }
        )
        guard let enumerator else { return root }

        // The root is a directory like any other: a file added directly to it changes its time.
        guard let rootDate = modificationDate(of: target), rootDate < started else { return root }

        // The enumerator reports paths with symbolic links resolved, such as /private/var for /var; the names are
        // appended to the root as it was given instead.
        var components: [String] = []
        for case let url as URL in enumerator {
            if let unreadable { return unreadable }

            components.removeSubrange(min(enumerator.level - 1, components.count)...)
            components.append(url.lastPathComponent)
            let path = components.reduce(root) { $0.appending($1) }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let date = values.contentModificationDate
            else { return path }

            let name = url.lastPathComponent
            if values.isDirectory == true, values.isSymbolicLink != true {
                if skippedDirectories.contains(name) {
                    enumerator.skipDescendants()
                    // The user's schemes are not skipped with the rest of their state.
                    if name == "xcuserdata", let change = firstChange(inUserData: path, started: started) {
                        return change
                    }

                    continue
                }

                if date >= started { return path }

                continue
            }

            if skippedFiles.contains(name) { continue }

            let limit = compiledExtensions.contains(url.pathExtension.lowercased()) ? completed : started
            if date >= limit { return path }
        }

        return unreadable
    }

    /// The schemes of an `xcuserdata` directory, which Xcode builds from, that changed after `started`. The
    /// directories around them are the user's state, which Xcode rewrites without it changing what is built.
    private static func firstChange(inUserData directory: FilePath, started: Date) -> FilePath? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory.url,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return directory }

        var components: [String] = []
        for case let url as URL in enumerator {
            components.removeSubrange(min(enumerator.level - 1, components.count)...)
            components.append(url.lastPathComponent)
            guard url.pathExtension == "xcscheme" else { continue }

            let scheme = components.reduce(directory) { $0.appending($1) }
            guard let date = modificationDate(of: scheme), date < started else { return scheme }
        }

        return nil
    }

    private static func modificationDate(of path: FilePath) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.string) else { return nil }

        return attributes[.modificationDate] as? Date
    }
}

import SystemPackage

/// A target of an Xcode project that the scanned schemes do not build, and that consumes code the scan
/// did read. None of its files has an index unit, so a use it makes of scanned code is not in the graph.
public struct UnscannedTarget: Equatable {
    public let name: String
    /// The Swift files the target compiles. Its uses are read from these by syntax alone.
    public let swiftSourceFiles: Set<FilePath>
    /// The files of `swiftSourceFiles` that a scanned target compiles too. The unscanned target has its own
    /// copy of what they declare, which the rest of its files use without any access modifier.
    public let sharedSourceFiles: Set<FilePath>

    // Only the Xcode driver, which exists on macOS alone, finds such targets, so on Linux nothing builds one.
    #if os(macOS)
        public init(name: String, swiftSourceFiles: Set<FilePath>, sharedSourceFiles: Set<FilePath>) {
            self.name = name
            self.swiftSourceFiles = swiftSourceFiles
            self.sharedSourceFiles = sharedSourceFiles
        }
    #endif
}

/// The names the Swift files of one unscanned target use.
public struct UnscannedTargetNames: Equatable {
    /// The names of every file of the target.
    public var all = NameSites()
    /// The names of the files that import a module with `@testable`, by module: only those files can use the
    /// module's internal declarations, since an import is file-scoped.
    public var testable: [String: NameSites] = [:]
    /// The files the target compiles that a scanned target compiles too, normalized.
    public var sharedSourceFiles: Set<FilePath> = []

    public init() {}
}

import SystemPackage

/// Whether the index has a unit for every C and Objective-C implementation file the build compiled.
/// Objective-C references to Swift declarations come from those units (`ObjCReferenceIndexer`), so a
/// declaration accessible from Objective-C is certainly unused only when none of them is missing.
public struct ClangCoverage: Equatable {
    /// A target of the project and every source file it compiles, Swift and clang alike.
    public struct Target: Equatable {
        public let sourceFiles: Set<FilePath>

        public init(sourceFiles: Set<FilePath>) {
            self.sourceFiles = sourceFiles
        }
    }

    /// C and Objective-C implementation files of built targets that have no index unit, sorted.
    public let unindexedFiles: [FilePath]

    public var isComplete: Bool {
        unindexedFiles.isEmpty
    }

    public init(unindexedFiles: [FilePath]) {
        self.unindexedFiles = unindexedFiles
    }

    /// A target counts as built when any of its source files has a unit. Within a built target, every
    /// implementation file with no unit is unindexed. Headers have no unit of their own; their
    /// occurrences are in the records of the units that include them.
    ///
    /// A target with no units at all is ambiguous: in a store Lethen has just built it was not compiled
    /// (the scanned schemes or products leave it out, and its Swift files are not indexed either), so it
    /// is missing nothing. A store Lethen did not build (`--skip-build`, `--index-store-path`) can be
    /// partial, so `trustsAbsentUnits` is false there and such a target's implementation files count as
    /// unindexed.
    ///
    /// Callers leave out the files the index collector drops: those of excluded targets, matching an
    /// index exclusion, or missing on disk.
    public static func assess(targets: [Target], indexedFiles: Set<FilePath>, trustsAbsentUnits: Bool) -> ClangCoverage {
        let indexed = Set(indexedFiles.map { $0.lexicallyNormalized() })
        var unindexed: Set<FilePath> = []

        for target in targets {
            let files = Set(target.sourceFiles.map { $0.lexicallyNormalized() })
            if trustsAbsentUnits, files.isDisjoint(with: indexed) { continue }

            for file in files where isImplementationFile(file) && !indexed.contains(file) {
                unindexed.insert(file)
            }
        }

        return ClangCoverage(unindexedFiles: unindexed.sorted { $0.string < $1.string })
    }

    /// Whether clang compiles the file into a unit of its own. Matches the collector, which lowercases
    /// the extension.
    public static func isImplementationFile(_ path: FilePath) -> Bool {
        guard let ext = path.extension?.lowercased() else { return false }

        return ProjectFileKind.clangSource.extensions.contains(ext)
    }

    /// The warning for an incomplete coverage, or `nil` when it is complete.
    public var warning: String? {
        guard !isComplete else { return nil }

        let noun = unindexedFiles.count == 1 ? "Objective-C file has" : "Objective-C files have"
        return "\(unindexedFiles.count) \(noun) no index unit (\(Self.describe(unindexedFiles))), so declarations accessible from Objective-C are reported as likely rather than certain."
    }

    /// Up to three file names, then a count of the rest.
    public static func describe(_ files: [FilePath]) -> String {
        let names = files.prefix(3).map { $0.lastComponent?.string ?? $0.string }
        let rest = files.count - names.count
        return names.joined(separator: ", ") + (rest > 0 ? ", and \(rest) more" : "")
    }
}

import SystemPackage

/// What indexing found that makes a report less certain: names the index has no references for, and
/// whether every Objective-C file was read. Collected during indexing, then read by `ConfidenceAssessor`.
public struct ConfidenceEvidence: Equatable {
    /// Identifier-like words found in string literals across the scanned sources.
    public private(set) var literalTokens: Set<String> = []
    /// Names used in `#if` clauses this build did not compile, by the module whose file has the clause,
    /// each with the clause that uses it.
    public private(set) var skippedBranches: [String: NameSites] = [:]
    /// Names used by the Swift files of targets the scanned schemes do not build, by target name.
    public private(set) var unscannedTargets: [String: UnscannedTargetNames] = [:]
    /// Whether the index has a unit for every C and Objective-C file the build compiled. `nil` until the
    /// pipeline records it, and for project kinds that cannot list their source files.
    public var clangCoverage: ClangCoverage?

    public init() {}

    public mutating func addLiteralTokens(_ tokens: Set<String>) {
        literalTokens.formUnion(tokens)
    }

    public mutating func addSkippedBranchNames(_ sites: NameSites, modules: Set<String>) {
        for module in modules {
            skippedBranches[module, default: NameSites()].merge(sites)
        }
    }

    /// Records the names one file of an unscanned target uses, keeping the smallest site for each name, and
    /// the files the target shares with scanned targets. `testableModules` are the modules that file imports
    /// with `@testable`: its names also count toward those modules' internal declarations.
    public mutating func addUnscannedTargetNames(
        _ sites: NameSites,
        target: String,
        sharedSourceFiles: Set<FilePath> = [],
        testableModules: Set<String> = []
    ) {
        var entry = unscannedTargets[target] ?? UnscannedTargetNames()
        entry.all.merge(sites)
        for module in testableModules {
            entry.testable[module, default: NameSites()].merge(sites)
        }
        entry.sharedSourceFiles.formUnion(sharedSourceFiles.map { $0.lexicallyNormalized() })
        unscannedTargets[target] = entry
    }

    /// Whether any name evidence beyond string literals exists, which is what the origin walk reads.
    var hasNameEvidence: Bool {
        !unscannedTargets.isEmpty || !skippedBranches.isEmpty
    }

    /// Unions the evidence, keeping the smallest site for each name and this value's clang coverage unless it has none.
    public mutating func merge(_ other: ConfidenceEvidence) {
        literalTokens.formUnion(other.literalTokens)
        for (module, sites) in other.skippedBranches {
            skippedBranches[module, default: NameSites()].merge(sites)
        }
        for (target, names) in other.unscannedTargets {
            var entry = unscannedTargets[target] ?? UnscannedTargetNames()
            entry.all.merge(names.all)
            for (module, sites) in names.testable {
                entry.testable[module, default: NameSites()].merge(sites)
            }
            entry.sharedSourceFiles.formUnion(names.sharedSourceFiles)
            unscannedTargets[target] = entry
        }
        if clangCoverage == nil { clangCoverage = other.clangCoverage }
    }
}

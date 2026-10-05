import SystemPackage

/// What indexing found that makes a report less certain: names the index has no references for, and
/// whether every Objective-C file was read. Collected during indexing, then read by `ConfidenceAssessor`.
public struct ConfidenceEvidence: Equatable {
    /// Identifier-like words found in the string literals of the scanned Swift sources. Only a declaration the
    /// Objective-C runtime can reach is named by a bare literal; a pure-Swift one is named by `reflectionSites`.
    public private(set) var literalTokens: Set<String> = []
    /// Identifier-like words found in the string literals of the scanned C and Objective-C sources. The call that
    /// receives such a literal is not read, so it may name any declaration.
    public private(set) var clangLiteralTokens: Set<String> = []
    /// Selector-shaped literals (`"load:from:"`) of the scanned Swift sources, whole. One names only the method
    /// whose Objective-C selector it spells, so it is not split into `literalTokens`.
    public private(set) var literalSelectors: Set<String> = []
    /// The selector-shaped literals and `@selector(...)` expressions of the scanned C and Objective-C sources, whole.
    public private(set) var clangLiteralSelectors: Set<String> = []
    /// Identifiers passed to a reflection or dynamic-lookup API in the scanned Swift sources, each with the
    /// smallest such call site, such as `NSClassFromString at File.swift:12`.
    public private(set) var reflectionSites: [String: String] = [:]
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

    public mutating func addClangLiteralTokens(_ tokens: Set<String>) {
        clangLiteralTokens.formUnion(tokens)
    }

    public mutating func addLiteralSelectors(_ selectors: Set<String>) {
        literalSelectors.formUnion(selectors)
    }

    public mutating func addClangLiteralSelectors(_ selectors: Set<String>) {
        clangLiteralSelectors.formUnion(selectors)
    }

    public mutating func addReflectionSites(_ sites: [String: String]) {
        for (name, site) in sites where reflectionSites[name].map({ $0 > site }) ?? true {
            reflectionSites[name] = site
        }
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
}

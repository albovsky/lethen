import Configuration

/// One pass of index phase two over an `IndexedFile`. An analysis reads the syntax with the visitor it owns,
/// joins what it finds to the file's declarations and references by location, and records the result on them.
protocol SyntaxAnalysis {
    init(configuration: Configuration)
    func apply(to file: IndexedFile) throws
}

enum SyntaxAnalysisList {
    /// The analyses `SwiftIndexer` runs after the prelude of phase two, in the order they run.
    static let all: [SyntaxAnalysis.Type] = [
        EnumCasePatternAnalysis.self,
        ValueUseAnalysis.self,
        StringLiteralAnalysis.self,
        SkippedBranchAnalysis.self,
        UnusedParameterAnalysis.self,
    ]
}

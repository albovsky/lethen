import Foundation
import SourceGraph
import SystemPackage

public struct IndexPlan {
    public let sourceFiles: [SourceFile: [IndexUnit]]
    /// C and Objective-C files, kept out of the Swift indexer.
    public let clangSourceFiles: [SourceFile: [IndexUnit]]
    public let plistPaths: Set<FilePath>
    public let xibPaths: Set<FilePath>
    public let xcDataModelPaths: Set<FilePath>
    public let xcMappingModelPaths: Set<FilePath>
    /// Whether every C and Objective-C file the build compiled has an index unit; `nil` when the project
    /// kind cannot list its source files.
    public let clangCoverage: ClangCoverage?
    /// Targets the scanned schemes do not build that use scanned code. Their files have no index unit, so the
    /// names they use are read from syntax and downgrade the declarations they match.
    public let unscannedTargets: [UnscannedTarget]

    public init(
        sourceFiles: [SourceFile: [IndexUnit]],
        clangSourceFiles: [SourceFile: [IndexUnit]] = [:],
        plistPaths: Set<FilePath> = [],
        xibPaths: Set<FilePath> = [],
        xcDataModelPaths: Set<FilePath> = [],
        xcMappingModelPaths: Set<FilePath> = [],
        clangCoverage: ClangCoverage? = nil,
        unscannedTargets: [UnscannedTarget] = []
    ) {
        self.sourceFiles = sourceFiles
        self.clangSourceFiles = clangSourceFiles
        self.plistPaths = plistPaths
        self.xibPaths = xibPaths
        self.xcDataModelPaths = xcDataModelPaths
        self.xcMappingModelPaths = xcMappingModelPaths
        self.clangCoverage = clangCoverage
        self.unscannedTargets = unscannedTargets
    }
}

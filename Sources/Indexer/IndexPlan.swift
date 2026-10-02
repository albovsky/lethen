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

    public init(
        sourceFiles: [SourceFile: [IndexUnit]],
        clangSourceFiles: [SourceFile: [IndexUnit]] = [:],
        plistPaths: Set<FilePath> = [],
        xibPaths: Set<FilePath> = [],
        xcDataModelPaths: Set<FilePath> = [],
        xcMappingModelPaths: Set<FilePath> = [],
        clangCoverage: ClangCoverage? = nil
    ) {
        self.sourceFiles = sourceFiles
        self.clangSourceFiles = clangSourceFiles
        self.plistPaths = plistPaths
        self.xibPaths = xibPaths
        self.xcDataModelPaths = xcDataModelPaths
        self.xcMappingModelPaths = xcMappingModelPaths
        self.clangCoverage = clangCoverage
    }
}

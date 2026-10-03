import Configuration
import Foundation
import Logger
import Shared
import SourceGraph

public struct IndexPipeline {
    private let plan: IndexPlan
    private let graph: SourceGraphMutex
    private let logger: ContextualLogger
    private let configuration: Configuration
    private let swiftVersion: SwiftVersion

    public init(plan: IndexPlan, graph: SourceGraphMutex, logger: ContextualLogger, configuration: Configuration, swiftVersion: SwiftVersion) {
        self.plan = plan
        self.graph = graph
        self.logger = logger
        self.configuration = configuration
        self.swiftVersion = swiftVersion
    }

    /// Indexes the plan into the graph and returns the number of lines of code in its Swift source
    /// files, or `nil` unless the configuration asks for statistics.
    public func perform() throws -> Int? {
        let scannedLOC = try SwiftIndexer(
            sourceFiles: plan.sourceFiles,
            graph: graph,
            logger: logger,
            configuration: configuration,
            swiftVersion: swiftVersion
        ).perform()

        var clangCoverage = plan.clangCoverage
        if !plan.clangSourceFiles.isEmpty {
            let unreadFiles = try ObjCReferenceIndexer(
                sourceFiles: plan.clangSourceFiles,
                graph: graph,
                logger: logger,
                configuration: configuration
            ).perform()
            if !unreadFiles.isEmpty {
                clangCoverage = clangCoverage?.addingUnreadFiles(unreadFiles)
                // The drivers warned about unindexed files when planning; unread ones are only known now.
                if let warning = ClangCoverage(unindexedFiles: [], unreadFiles: unreadFiles).warning {
                    logger.warn(warning)
                }
            }
        }

        if !plan.unscannedTargets.isEmpty {
            try UnscannedTargetIndexer(
                targets: plan.unscannedTargets,
                graph: graph,
                logger: logger,
                configuration: configuration
            ).perform()
        }

        if !plan.plistPaths.isEmpty {
            try InfoPlistIndexer(
                infoPlistFiles: plan.plistPaths,
                graph: graph,
                logger: logger,
                configuration: configuration
            ).perform()
        }

        if !plan.xibPaths.isEmpty {
            try XibIndexer(
                xibFiles: plan.xibPaths,
                graph: graph,
                logger: logger,
                configuration: configuration
            ).perform()
        }

        if !plan.xcDataModelPaths.isEmpty {
            try XCDataModelIndexer(
                files: plan.xcDataModelPaths,
                graph: graph,
                logger: logger,
                configuration: configuration
            ).perform()
        }

        if !plan.xcMappingModelPaths.isEmpty {
            try XCMappingModelIndexer(
                files: plan.xcMappingModelPaths,
                graph: graph,
                logger: logger,
                configuration: configuration
            ).perform()
        }

        graph.withLock {
            $0.setClangCoverage(clangCoverage)
            $0.indexingComplete()
        }
        return scannedLOC
    }
}

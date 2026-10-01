import Configuration
import Foundation
import Indexer
import Logger
import PeripheryKit
import ProjectDrivers
import Shared
import SourceGraph

/// Builds, indexes, and analyzes a project. `Scan` does the work; tests substitute the results.
protocol ScanRunning {
    init(configuration: Configuration, logger: Logger, swiftVersion: SwiftVersion)
    func perform(project: Project) throws -> Scan.Output
}

final class Scan: ScanRunning {
    private let configuration: Configuration
    private let logger: Logger
    private let graph: SourceGraph
    private let swiftVersion: SwiftVersion
    private var sourceFileCount = 0
    private var lineCount: Int?

    required init(configuration: Configuration, logger: Logger, swiftVersion: SwiftVersion) {
        self.configuration = configuration
        self.logger = logger
        self.swiftVersion = swiftVersion
        graph = SourceGraph(configuration: configuration, logger: logger)
    }

    struct Output {
        let results: [ScanResult]
        /// The size of the scanned project, when the configuration asks for statistics.
        let statistics: ScanStatistics?
        /// The analyzed source graph, which `lethen explain` reads.
        let graph: SourceGraph?

        init(results: [ScanResult], statistics: ScanStatistics? = nil, graph: SourceGraph? = nil) {
            self.results = results
            self.statistics = statistics
            self.graph = graph
        }
    }

    /// Records which mutator retained each declaration, for `lethen explain`.
    var recordsRetentionSources: Bool {
        get { graph.recordsRetentionSources }
        set { graph.recordsRetentionSources = newValue }
    }

    /// Build arguments quoted as if for a shell, such as `'/tmp/Build Space'`, `--scratch-path='/tmp/Build Space'`, or
    /// the build setting `OTHER_SWIFT_FLAGS='-DA -DB'`. Commands used to run through a shell, which removed such quotes;
    /// they now reach the build tool as written.
    static func shellQuotedArguments(_ arguments: [String]) -> [String] {
        func isQuoted(_ text: Substring) -> Bool {
            text.count >= 2 && ["'", "\""].contains { text.hasPrefix($0) && text.hasSuffix($0) }
        }

        return arguments.filter { argument in
            if isQuoted(argument[...]) {
                return true
            }

            // An option's value or a build setting's value after the first `=`.
            guard let equals = argument.firstIndex(of: "=") else { return false }

            return isQuoted(argument[argument.index(after: equals)...])
        }
    }

    func perform(project: Project) throws -> Output {
        if !configuration.indexStorePath.isEmpty {
            logger.warn("When using the '--index-store-path' option please ensure that Xcode is not running. False-positives can occur if Xcode writes to the index store while lethen is running.")

            if !configuration.skipBuild {
                logger.warn("The '--index-store-path' option implies '--skip-build', specify it to silence this warning.")
                configuration.skipBuild = true
            }
        }

        for argument in Self.shellQuotedArguments(configuration.buildArguments + configuration.xcodeListArguments) {
            logger.warn("The build argument \(argument) reaches the build with its quotes, because lethen passes build arguments to the build tool as written, without a shell. Remove the quotes.")
        }

        let driver = try setup(project)

        // Output configuration after project setup as the driver may alter it.
        if configuration.verbose {
            let configYaml = try configuration.asYaml()
            logger.debug("[configuration:begin]\n\(configYaml.trimmed)\n[configuration:end]")
        }

        try build(driver)
        try index(driver)
        let declarationCount = graph.allDeclarations.count
        try analyze()
        let results = buildResults()
        let statistics = configuration.stats ? ScanStatistics(
            sourceFileCount: sourceFileCount,
            lineCount: lineCount,
            declarationCount: declarationCount
        ) : nil
        return Output(results: results, statistics: statistics, graph: graph)
    }

    // MARK: - Private

    private func setup(_ project: Project) throws -> ProjectDriver {
        let driverSetupInterval = logger.beginInterval("driver:setup")
        let driver = try project.driver()
        logger.endInterval(driverSetupInterval)
        return driver
    }

    private func build(_ driver: ProjectDriver) throws {
        let driverBuildInterval = logger.beginInterval("driver:build")
        try driver.build()
        logger.endInterval(driverBuildInterval)
    }

    private func index(_ driver: ProjectDriver) throws {
        let indexInterval = logger.beginInterval("index")

        if configuration.outputFormat.supportsAuxiliaryOutput {
            let asterisk = logger.colorize("*", .boldGreen)
            logger.info("\(asterisk) Indexing...")
        }

        let indexLogger = logger.contextualized(with: "index")
        let planInterval = logger.beginInterval("index:plan")
        let plan = try driver.plan(logger: indexLogger)
        logger.endInterval(planInterval)
        let graphMutex = SourceGraphMutex(graph: graph)
        let pipeline = IndexPipeline(plan: plan, graph: graphMutex, logger: indexLogger, configuration: configuration, swiftVersion: swiftVersion)
        lineCount = try pipeline.perform()
        sourceFileCount = plan.sourceFiles.count
        logger.endInterval(indexInterval)
    }

    private func analyze() throws {
        let analyzeInterval = logger.beginInterval("analyze")

        if configuration.outputFormat.supportsAuxiliaryOutput {
            let asterisk = logger.colorize("*", .boldGreen)
            logger.info("\(asterisk) Analyzing...")
        }

        try SourceGraphMutatorRunner(
            graph: graph,
            logger: logger,
            configuration: configuration,
            swiftVersion: swiftVersion
        ).perform()
        logger.endInterval(analyzeInterval)
    }

    private func buildResults() -> [ScanResult] {
        let resultInterval = logger.beginInterval("result:build")
        let results = ScanResultBuilder.build(for: graph, configuration: configuration)
        logger.endInterval(resultInterval)
        return results
    }
}

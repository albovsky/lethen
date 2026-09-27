import Configuration
import Foundation
import Indexer
import IndexStore
import Logger
import Shared

public protocol ProjectDriver {
    func build() throws
    func plan(logger: ContextualLogger) throws -> IndexPlan
}

public extension ProjectDriver {
    func build() throws {}

    func plan(logger _: ContextualLogger) throws -> IndexPlan {
        IndexPlan(sourceFiles: [:])
    }
}

extension BuildProgress {
    /// Progress for a project build, as selected by `--quiet`, `--verbose`, and `--format`.
    init(configuration: Configuration, logger: Logger) {
        self.init(
            mode: Self.mode(
                quiet: configuration.quiet,
                verbose: configuration.verbose,
                supportsAuxiliaryOutput: configuration.outputFormat.supportsAuxiliaryOutput
            ),
            logger: logger
        )
    }
}

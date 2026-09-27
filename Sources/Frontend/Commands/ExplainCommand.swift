import ArgumentParser
import Foundation
import Logger
import Shared
import SourceGraph
import SystemPackage

/// Scans like `lethen scan`, then explains one declaration instead of listing results.
struct ExplainCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Explain why a declaration is reported as unused, used, or retained",
        discussion: "Takes every option `lethen scan` takes, and scans the same way."
    )

    @Argument(help: "The declaration's USR, or its name with or without argument labels, optionally qualified by enclosing declarations: 'load', 'load(from:)', or 'Store.load'")
    var query: String

    @OptionGroup(title: "Scan options")
    var scan: ScanCommand

    func run() throws {
        let originalDirectory = FilePath.current
        defer { _ = FileManager.default.changeCurrentDirectoryPath(originalDirectory.string) }

        let configuration = try scan.makeConfiguration()
        let logger = Logger(configuration: configuration)
        let shell = ShellImpl(logger: logger)
        let swiftVersion = try SwiftVersion(shell: shell)
        try swiftVersion.validateVersion()
        let project = try Project(configuration: configuration, shell: shell, logger: logger)

        let scanner = Scan(configuration: configuration, logger: logger, swiftVersion: swiftVersion)
        scanner.recordsRetentionSources = true
        let output = try scanner.perform(project: project)
        guard let graph = output.graph else {
            throw LethenError.sourceGraphIntegrityError(message: "The scan produced no source graph to explain.")
        }

        let explainer = SourceGraphExplainer(graph: graph, configuration: configuration)
        let declarations = explainer.declarations(matching: query)
        guard !declarations.isEmpty else {
            throw LethenError.usageError("No declaration matches '\(query)'. Pass its name, such as 'load' or 'Store.load(from:)', or its USR as printed by '--format json'.")
        }

        if configuration.outputFormat.supportsAuxiliaryOutput {
            logger.info("", canQuiet: true)
        }
        logger.info(declarations.map(explainer.explain).joined(separator: "\n\n"), canQuiet: false)
    }
}

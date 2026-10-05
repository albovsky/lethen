import Configuration
import Foundation
import Logger
import Shared
import SourceGraph
import SystemPackage

final class GitHubActionsFormatter: OutputFormatter {
    let configuration: Configuration
    let logger: Logger
    lazy var currentFilePath: FilePath = .current

    init(configuration: Configuration, logger: Logger) {
        self.logger = logger
        self.configuration = configuration
    }

    func format(_ results: [ScanResult], colored: Bool) throws -> String? {
        guard !results.isEmpty else { return nil }
        guard configuration.relativeResults else { throw LethenError.usageError("`lethen scan` must be ran with `--relative-results` when using the GitHub Actions formatter") }

        return results.flatMap { result in
            describe(result, colored: colored).map { location, description in
                prefix(for: location, result: result) + Self.escapeData(description)
            }
        }
        .joined(separator: "\n")
    }

    /// Escapes a workflow command's message the way GitHub's toolkit does, so that a newline in
    /// a file or declaration name cannot end the command and start another one in the log.
    static func escapeData(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// Escapes a workflow command's property value, which also ends at `,` and `::`.
    static func escapeProperty(_ value: String) -> String {
        escapeData(value)
            .replacingOccurrences(of: ":", with: "%3A")
            .replacingOccurrences(of: ",", with: "%2C")
    }

    // MARK: - Private

    private func prefix(for location: Location, result: ScanResult) -> String {
        let path = Self.escapeProperty(outputPath(location).string)
        let lineNum = String(location.line)
        let column = location.column
        let title = Self.escapeProperty(describe(result.annotation))

        let command = result.confidence == .likely ? "notice" : "warning"

        return "::\(command) file=\(path),line=\(lineNum),col=\(column),title=\(title)::"
    }
}

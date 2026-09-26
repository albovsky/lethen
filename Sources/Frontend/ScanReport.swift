import Configuration
import Foundation
import Logger
import PeripheryKit
import Shared

/// The results a scan reports once the baseline and report filters are applied, with the files the
/// configuration asks for.
struct ScanReport {
    /// The results left after filtering.
    let results: [ScanResult]
    /// The formatted results for the terminal, colored when the format and the terminal support it.
    let output: String?

    private let configuration: Configuration
    private let formatter: OutputFormatter
    private let isColored: Bool

    /// Loads the baseline, filters `results`, writes the new baseline, and formats the results.
    init(results: [ScanResult], configuration: Configuration, logger: Logger) throws {
        var baseline: Baseline?

        if let baselinePath = configuration.baseline {
            let data = try Data(contentsOf: baselinePath.url)
            baseline = try JSONDecoder().decode(Baseline.self, from: data)
        }

        let filteredResults = try OutputDeclarationFilter(configuration: configuration, logger: logger).filter(results, with: baseline)

        if let baselinePath = configuration.writeBaseline {
            let usrs = filteredResults
                .flatMapSet { $0.usrs }
                .union(baseline?.usrs ?? [])
            let baseline = Baseline.v1(usrs: usrs.sorted())
            let data = try JSONEncoder().encode(baseline)
            try data.write(to: baselinePath.url)
        }

        let outputFormat = configuration.outputFormat
        let formatter = outputFormat.formatter.init(configuration: configuration, logger: logger)
        let isColored = outputFormat.supportsColoredOutput && logger.isColoredOutputEnabled

        self.results = filteredResults
        output = try formatter.format(filteredResults, colored: isColored)
        self.configuration = configuration
        self.formatter = formatter
        self.isColored = isColored
    }

    /// Writes the results file, without color, when the configuration names one. The file is written
    /// even when there are no results.
    func writeResults() throws {
        guard let resultsPath = configuration.writeResults else { return }

        let output: String = if isColored {
            // The formatted output contains ANSI escape codes, so we need to re-format
            // with coloring disabled.
            try formatter.format(results, colored: false) ?? ""
        } else {
            self.output ?? ""
        }

        try output.write(to: resultsPath.url, atomically: true, encoding: .utf8)
    }

    /// Throws `foundIssues` in strict mode when any result remains.
    func validateStrictMode() throws {
        if !results.isEmpty, configuration.strict {
            throw LethenError.foundIssues(count: results.count)
        }
    }
}

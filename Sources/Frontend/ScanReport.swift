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
    /// `output` in the groups the terminal prints: in the xcode format, the `certain` dead code, then the `likely` dead
    /// code and then the access-level and ignore-comment results, each of the last two after a header that goes to
    /// standard error unless quiet. Otherwise one group without a header.
    let sections: [Section]
    /// The summary printed on standard error after the xcode format's results, unless quiet: the
    /// counts, how many `--min-confidence` hid, and where to go next.
    let footer: String?

    struct Section {
        let header: String?
        let output: String
    }

    static let likelyHeader = "Likely unused, check by hand:"
    static let housekeepingHeader = "Redundant public accessibility and superfluous ignore comments:"

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

        let printsFooter = configuration.outputFormat == .xcode && !configuration.quiet
        let filter = OutputDeclarationFilter(configuration: configuration, logger: logger, notesHiddenResults: !printsFooter)
        var filteredResults = try filter.filter(results, with: baseline)
        let isGrouped = configuration.outputFormat == .xcode
        let groups = isGrouped ? Self.groups(of: filteredResults) : [(header: nil, results: filteredResults)]
        if isGrouped {
            filteredResults = groups.flatMap(\.results)
        }

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
        sections = try groups.count == 1
            ? output.map { [Section(header: groups[0].header, output: $0)] } ?? []
            : groups.compactMap { group in
                try formatter.format(group.results, colored: isColored).map { Section(header: group.header, output: $0) }
            }
        footer = printsFooter ? Self.footer(for: filteredResults, hiddenByConfidence: filter.hiddenByConfidenceCount, configuration: configuration) : nil
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

    /// The xcode format's groups, each in the filter's order: dead code that is `certain`, dead code that is `likely`,
    /// and the results that are not dead code. Groups without results are left out; only the `certain` one has no
    /// header.
    static func groups(of results: [ScanResult]) -> [(header: String?, results: [ScanResult])] {
        let housekeeping = results.filter { !$0.kind.isDeadCode }
        let deadCode = results.filter(\.kind.isDeadCode)
        let groups: [(header: String?, results: [ScanResult])] = [
            (nil, deadCode.filter { $0.confidence == .certain }),
            (likelyHeader, deadCode.filter { $0.confidence == .likely }),
            (housekeepingHeader, housekeeping),
        ]
        let nonEmpty = groups.filter { !$0.results.isEmpty }
        return nonEmpty.isEmpty ? [(nil, [])] : nonEmpty
    }

    /// "3 results, 1 likely. `lethen explain <name>` shows why; …", or only the `--min-confidence`
    /// note when no result remains. The baseline hint is left out once a baseline is in use.
    static func footer(for results: [ScanResult], hiddenByConfidence: Int, configuration: Configuration) -> String? {
        let hidden = hiddenByConfidence > 0
            ? OutputDeclarationFilter.hiddenByConfidenceDescription(count: hiddenByConfidence, minimum: configuration.minConfidence)
            : nil

        guard !results.isEmpty else {
            return hidden.map { $0 + "." }
        }

        var summary = "\(results.count) \(results.count == 1 ? "result" : "results")"
        let kinds = ScanResult.Kind.allCases.compactMap { kind -> String? in
            let count = results.count { $0.kind == kind }
            return count > 0 ? "\(count) \(kind.summaryName)" : nil
        }

        if kinds.count > 1 {
            summary += " (\(kinds.joined(separator: ", ")))"
        }

        let likelyCount = results.count { $0.confidence == .likely }

        if likelyCount > 0 {
            summary += ", \(likelyCount) likely"
        }

        if let hidden {
            summary += "; \(hidden)"
        }

        summary += ". `lethen explain <name>` shows why"

        if configuration.baseline == nil, configuration.writeBaseline == nil {
            summary += "; `--write-baseline baseline.json` records these so the next scan reports only new ones"
        }

        return summary + "."
    }

    /// Throws `foundIssues` in strict mode when any result remains.
    func validateStrictMode() throws {
        if !results.isEmpty, configuration.strict {
            throw LethenError.foundIssues(count: results.count)
        }
    }
}

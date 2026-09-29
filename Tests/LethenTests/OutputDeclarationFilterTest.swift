import Configuration
import Foundation
import Logger
@testable import PeripheryKit
@testable import SourceGraph
import SystemPackage
import XCTest

final class OutputDeclarationFilterTest: XCTestCase {
    private let root = FilePath.current
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    func testBaselineDropsResultsWhoseSymbolIsListed() throws {
        let kept = result(name: "Kept", usr: "s:Kept")
        let baselined = result(name: "Old", usr: "s:Old")
        let filtered = try filter([kept, baselined], configuration: Configuration(), baseline: .v1(usrs: ["s:Old"]))
        XCTAssertEqual(filtered.map(\.declaration.name), ["Kept"])
    }

    func testSuperfluousIgnoreResultsAreKeyedSeparatelyFromTheirDeclaration() throws {
        let superfluous = result(name: "Ignored", usr: "s:Ignored", annotation: .superfluousIgnoreCommand)
        XCTAssertEqual(superfluous.usrs, ["superfluous-ignore-s:Ignored"])
        let notFiltered = try filter([superfluous], configuration: Configuration(), baseline: .v1(usrs: ["s:Ignored"]))
        XCTAssertEqual(notFiltered.count, 1)
        let filtered = try filter([superfluous], configuration: Configuration(), baseline: .v1(usrs: ["superfluous-ignore-s:Ignored"]))
        XCTAssertTrue(filtered.isEmpty)
    }

    func testReportExcludeDropsMatchingFiles() throws {
        let configuration = Configuration()
        configuration.reportExclude = ["Sources/Generated/*.swift"]
        configuration.buildFilenameMatchers()
        let generated = result(name: "Generated", usr: "s:Generated", path: "Sources/Generated/G.swift")
        let handwritten = result(name: "Handwritten", usr: "s:Handwritten", path: "Sources/A.swift")
        let filtered = try filter([generated, handwritten], configuration: configuration, baseline: nil)
        XCTAssertEqual(filtered.map(\.declaration.name), ["Handwritten"])
    }

    func testReportIncludeSupersedesReportExclude() throws {
        let configuration = Configuration()
        configuration.reportExclude = ["Sources/**/*.swift"]
        configuration.reportInclude = ["Sources/A.swift"]
        configuration.buildFilenameMatchers()
        let included = result(name: "Included", usr: "s:Included", path: "Sources/A.swift")
        let other = result(name: "Other", usr: "s:Other", path: "Sources/B.swift")
        let filtered = try filter([other, included], configuration: configuration, baseline: nil)
        XCTAssertEqual(filtered.map(\.declaration.name), ["Included"])
    }

    func testResultsAreSortedByLocation() throws {
        let later = result(name: "Later", usr: "s:Later", path: "Sources/B.swift", line: 1)
        let earlierFile = result(name: "EarlierFile", usr: "s:EarlierFile", path: "Sources/A.swift", line: 20)
        let earlierLine = result(name: "EarlierLine", usr: "s:EarlierLine", path: "Sources/A.swift", line: 2)
        let filtered = try filter([later, earlierFile, earlierLine], configuration: Configuration(), baseline: nil)
        XCTAssertEqual(filtered.map(\.declaration.name), ["EarlierLine", "EarlierFile", "Later"])
    }

    func testCertainResultsSortBeforeLikelyOnes() throws {
        let likely = result(name: "Likely", usr: "s:Likely", line: 1, confidence: .likely)
        let certain = result(name: "Certain", usr: "s:Certain", line: 2)
        let filtered = try filter([likely, certain], configuration: Configuration(), baseline: nil)
        XCTAssertEqual(filtered.map(\.declaration.name), ["Certain", "Likely"])
    }

    // MARK: - Minimum confidence

    func testDefaultMinimumConfidenceReportsLikelyResults() throws {
        let likely = result(name: "Likely", usr: "s:Likely", confidence: .likely)
        let certain = result(name: "Certain", usr: "s:Certain")
        let notes = try captureOutput(of: STDERR_FILENO) {
            let filtered = try filter([likely, certain], configuration: Configuration(), baseline: nil, logger: loudLogger)
            XCTAssertEqual(filtered.map(\.declaration.name), ["Certain", "Likely"])
        }
        XCTAssertEqual(notes, "")
    }

    func testMinimumConfidenceCertainHidesLikelyResultsAndSaysHowMany() throws {
        let configuration = Configuration()
        configuration.minConfidence = .certain
        let results = [
            result(name: "LikelyA", usr: "s:LikelyA", line: 1, confidence: .likely),
            result(name: "CertainB", usr: "s:CertainB", line: 3),
            result(name: "LikelyC", usr: "s:LikelyC", line: 5, confidence: .likely),
            result(name: "CertainA", usr: "s:CertainA", line: 2),
        ]
        let notes = try captureOutput(of: STDERR_FILENO) {
            let filtered = try filter(results, configuration: configuration, baseline: nil, logger: loudLogger)
            XCTAssertEqual(filtered.map(\.declaration.name), ["CertainA", "CertainB"])
        }
        XCTAssertEqual(notes, "--min-confidence certain hid 2 results.\n")
    }

    func testMinimumConfidenceNoteIsSingularForOneResult() throws {
        let configuration = Configuration()
        configuration.minConfidence = .certain
        let notes = try captureOutput(of: STDERR_FILENO) {
            _ = try filter([result(name: "Likely", usr: "s:Likely", confidence: .likely)], configuration: configuration, baseline: nil, logger: loudLogger)
        }
        XCTAssertEqual(notes, "--min-confidence certain hid 1 result.\n")
    }

    func testMinimumConfidenceNoteIsQuietWhenNothingIsHidden() throws {
        let configuration = Configuration()
        configuration.minConfidence = .certain
        let notes = try captureOutput(of: STDERR_FILENO) {
            let filtered = try filter([result(name: "Certain", usr: "s:Certain")], configuration: configuration, baseline: nil, logger: loudLogger)
            XCTAssertEqual(filtered.count, 1)
        }
        XCTAssertEqual(notes, "")
    }

    func testMinimumConfidenceNoteIsSuppressedByQuiet() throws {
        let configuration = Configuration()
        configuration.minConfidence = .certain
        let notes = try captureOutput(of: STDERR_FILENO) {
            let filtered = try filter([result(name: "Likely", usr: "s:Likely", confidence: .likely)], configuration: configuration, baseline: nil)
            XCTAssertTrue(filtered.isEmpty)
        }
        XCTAssertEqual(notes, "")
    }

    /// The baseline runs first: a baselined `likely` result still counts as matched, so the baseline
    /// does not warn, and it is not counted as hidden by the confidence filter.
    func testBaselineIsAppliedBeforeMinimumConfidence() throws {
        let configuration = Configuration()
        configuration.minConfidence = .certain
        let results = [
            result(name: "BaselinedLikely", usr: "s:BaselinedLikely", line: 1, confidence: .likely),
            result(name: "Likely", usr: "s:Likely", line: 2, confidence: .likely),
            result(name: "Certain", usr: "s:Certain", line: 3),
        ]
        let notes = try captureOutput(of: STDERR_FILENO) {
            let filtered = try filter(results, configuration: configuration, baseline: .v1(usrs: ["s:BaselinedLikely"]), logger: loudLogger)
            XCTAssertEqual(filtered.map(\.declaration.name), ["Certain"])
        }
        XCTAssertEqual(notes, "--min-confidence certain hid 1 result.\n")
    }

    func testMinimumConfidenceAppliesWithReportGlobs() throws {
        let configuration = Configuration()
        configuration.minConfidence = .certain
        configuration.reportExclude = ["Sources/Generated/*.swift"]
        configuration.buildFilenameMatchers()
        let results = [
            result(name: "Generated", usr: "s:Generated", path: "Sources/Generated/G.swift"),
            result(name: "Likely", usr: "s:Likely", confidence: .likely),
            result(name: "Certain", usr: "s:Certain"),
        ]
        let filtered = try filter(results, configuration: configuration, baseline: nil)
        XCTAssertEqual(filtered.map(\.declaration.name), ["Certain"])
    }

    // MARK: - Private

    private let loudLogger = Logger(quiet: false, verbose: false, colorMode: .never)

    private func filter(_ results: [ScanResult], configuration: Configuration, baseline: Baseline?, logger: Logger? = nil) throws -> [ScanResult] {
        try OutputDeclarationFilter(configuration: configuration, logger: logger ?? self.logger).filter(results, with: baseline)
    }

    private func result(name: String, usr: String, path: String = "Sources/A.swift", line: Int = 1, annotation: ScanResult.Annotation = .unused, confidence: Confidence = .certain) -> ScanResult {
        let location = Location(file: SourceFile(path: root.appending(path), modules: ["App"]), line: line, column: 1)
        let declaration = Declaration(name: name, kind: .class, usrs: [usr], location: location)
        return ScanResult(declaration: declaration, annotation: annotation, confidence: confidence)
    }
}

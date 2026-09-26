import Configuration
import Foundation
@testable import Frontend
import Logger
@testable import PeripheryKit
import Shared
@testable import SourceGraph
import SystemPackage
import XCTest

final class ScanReportTest: XCTestCase {
    private let root = FilePath.current
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)
    private var directory: FilePath!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lethen-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = FilePath(url.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory.string)
        try super.tearDownWithError()
    }

    // MARK: - Baseline

    func testMissingBaselineFileIsAnError() {
        let configuration = Configuration()
        configuration.baseline = directory.appending("missing.json")

        XCTAssertThrowsError(try ScanReport(results: [result("Kept")], configuration: configuration, logger: logger))
    }

    func testBaselineDropsListedSymbols() throws {
        let configuration = Configuration()
        configuration.baseline = try writeBaseline(["s:Old"])

        let report = try ScanReport(results: [result("Kept"), result("Old")], configuration: configuration, logger: logger)
        XCTAssertEqual(report.results.map(\.declaration.name), ["Kept"])
    }

    func testBaselineWarnsWhenNothingMatched() throws {
        let configuration = Configuration()
        configuration.baseline = try writeBaseline(["s:Gone"])
        let logger = Logger(quiet: false, verbose: false, colorMode: .never)

        let warnings = try captureOutput(of: STDERR_FILENO) {
            let report = try ScanReport(results: [result("Kept")], configuration: configuration, logger: logger)
            XCTAssertEqual(report.results.count, 1)
        }
        XCTAssertEqual(warnings, "warning: No results were filtered by the baseline.\n")
    }

    func testWriteBaselineWritesSortedUnionOfOldAndNewSymbols() throws {
        let configuration = Configuration()
        configuration.baseline = try writeBaseline(["s:Old", "s:Gone"])
        configuration.writeBaseline = directory.appending("new.json")

        _ = try ScanReport(results: [result("Old"), result("Zed"), result("Kept")], configuration: configuration, logger: logger)

        let written = try String(contentsOfFile: directory.appending("new.json").string, encoding: .utf8)
        XCTAssertEqual(written, #"{"v1":{"usrs":["s:Gone","s:Kept","s:Old","s:Zed"]}}"#)
    }

    func testWriteBaselineWithoutInputBaselineRecordsResults() throws {
        let configuration = Configuration()
        configuration.writeBaseline = directory.appending("new.json")

        _ = try ScanReport(results: [result("B"), result("A")], configuration: configuration, logger: logger)

        let written = try String(contentsOfFile: directory.appending("new.json").string, encoding: .utf8)
        XCTAssertEqual(written, #"{"v1":{"usrs":["s:A","s:B"]}}"#)
    }

    // MARK: - Results file

    func testWriteResultsIsWrittenWithNoResults() throws {
        let configuration = Configuration()
        configuration.writeResults = directory.appending("results.txt")

        let report = try ScanReport(results: [], configuration: configuration, logger: logger)
        try report.writeResults()

        let written = try String(contentsOfFile: directory.appending("results.txt").string, encoding: .utf8)
        XCTAssertEqual(written, "* No unused code detected.")
        XCTAssertEqual(written, report.output)
    }

    func testWriteResultsIsNotColoredWhenTerminalOutputIs() throws {
        let configuration = Configuration()
        configuration.relativeResults = true
        configuration.writeResults = directory.appending("results.txt")
        let coloredLogger = Logger(quiet: true, verbose: false, colorMode: .always)

        let report = try ScanReport(results: [result("Foo")], configuration: configuration, logger: coloredLogger)
        try report.writeResults()

        XCTAssertTrue(try XCTUnwrap(report.output).contains("\u{1B}["))
        let written = try String(contentsOfFile: directory.appending("results.txt").string, encoding: .utf8)
        XCTAssertEqual(written, "Sources/A.swift:1:1: warning: Unused class 'Foo'")
    }

    func testWriteResultsMatchesUncoloredFormats() throws {
        let configuration = Configuration()
        configuration.outputFormat = .json
        configuration.writeResults = directory.appending("results.json")
        let coloredLogger = Logger(quiet: true, verbose: false, colorMode: .always)

        let report = try ScanReport(results: [result("Foo")], configuration: configuration, logger: coloredLogger)
        try report.writeResults()

        let written = try String(contentsOfFile: directory.appending("results.json").string, encoding: .utf8)
        XCTAssertEqual(written, report.output)
        XCTAssertFalse(written.contains("\u{1B}["))
    }

    func testNoResultsFileUnlessRequested() throws {
        let report = try ScanReport(results: [result("Foo")], configuration: Configuration(), logger: logger)
        try report.writeResults()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.string), [])
    }

    // MARK: - Strict mode

    func testStrictModeThrowsFoundIssuesWithFilteredCount() throws {
        let configuration = Configuration()
        configuration.strict = true
        configuration.baseline = try writeBaseline(["s:Old"])

        let report = try ScanReport(results: [result("A"), result("B"), result("Old")], configuration: configuration, logger: logger)

        XCTAssertThrowsError(try report.validateStrictMode()) { error in
            guard case let .foundIssues(count) = error as? LethenError else {
                return XCTFail("Expected foundIssues, got: \(error)")
            }

            XCTAssertEqual(count, 2)
        }
    }

    func testStrictModeAcceptsNoResults() throws {
        let configuration = Configuration()
        configuration.strict = true
        configuration.baseline = try writeBaseline(["s:Old"])

        let report = try ScanReport(results: [result("Old")], configuration: configuration, logger: logger)
        XCTAssertNoThrow(try report.validateStrictMode())
    }

    func testResultsDoNotThrowWithoutStrictMode() throws {
        let report = try ScanReport(results: [result("A")], configuration: Configuration(), logger: logger)
        XCTAssertNoThrow(try report.validateStrictMode())
    }

    // MARK: - Private

    private func writeBaseline(_ usrs: [String]) throws -> FilePath {
        let path = directory.appending("baseline-\(UUID().uuidString).json")
        try JSONEncoder().encode(Baseline.v1(usrs: usrs)).write(to: path.url)
        return path
    }

    private func result(_ name: String) -> ScanResult {
        let location = Location(file: SourceFile(path: root.appending("Sources/A.swift"), modules: ["App"]), line: 1, column: 1)
        let declaration = Declaration(name: name, kind: .class, usrs: ["s:\(name)"], location: location)
        return ScanResult(declaration: declaration, annotation: .unused)
    }
}

import Configuration
import Foundation
@testable import Frontend
@testable import Indexer
@testable import Logger
@testable import SourceGraph
import SystemPackage
@testable import TestShared
import XCTest

/// `--stats`: phase timings and project size on standard error, with results on standard output left intact.
final class ScanStatisticsTest: FixtureSourceGraphTestCase {
    // MARK: - Command

    func testStatsReportPhaseTimingsAndLeaveJSONOutputValid() throws {
        let (output, errorOutput) = try scanFixture(["--format", "json", "--stats"])

        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]], output)
        XCTAssertFalse(results.isEmpty)

        let report = errorOutput.components(separatedBy: "\n")
        XCTAssertEqual(report.first, "Scan statistics:", errorOutput)
        let labels = report.dropFirst().map { $0.trimmingCharacters(in: .whitespaces).components(separatedBy: "  ").first ?? "" }
        XCTAssertEqual(
            labels.filter { !$0.isEmpty },
            ["Setup", "Build", "Index", "Plan", "Swift phase one", "Swift phase two", "Analyze", "Results", "Output", "Total", "Source files", "Lines of code", "Throughput", "Declarations"],
            errorOutput
        )
        XCTAssertGreaterThan(try value(of: "Source files", in: report), 0)
        XCTAssertGreaterThan(try value(of: "Lines of code", in: report), 0)
        XCTAssertGreaterThan(try value(of: "Declarations", in: report), 0)
    }

    func testScanWithoutStatsPrintsNoReport() throws {
        let (output, errorOutput) = try scanFixture(["--format", "json"])

        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]], output)
        XCTAssertFalse(errorOutput.contains("Scan statistics"), errorOutput)
    }

    // MARK: - Line counting

    func testLinesAreCountedOnlyWithStats() throws {
        let plan = try XCTUnwrap(Self.plan)
        let physicalLines = try plan.sourceFiles.keys.reduce(into: 0) { count, file in
            count += try String(contentsOfFile: file.path.string, encoding: .utf8).components(separatedBy: "\n").count
        }

        XCTAssertNil(try indexFixture(stats: false))

        let lineCount = try XCTUnwrap(indexFixture(stats: true))
        XCTAssertGreaterThan(lineCount, 0)
        XCTAssertLessThan(lineCount, physicalLines, "Blank and comment-only lines are not counted")
    }

    // MARK: - Interval recording

    func testLoggerRecordsIntervalsOnlyWithARecorder() {
        let silent = Logger(quiet: true, verbose: false, colorMode: .never)
        XCTAssertNil(silent.intervalRecorder)
        XCTAssertNil(silent.beginInterval("index").start)

        let recorder = IntervalRecorder()
        let logger = Logger(quiet: true, verbose: false, colorMode: .never, intervalRecorder: recorder)
        let interval = logger.contextualized(with: "index").beginInterval("index")
        XCTAssertNotNil(interval.start)
        logger.endInterval(interval)

        XCTAssertEqual(Array(recorder.durations.keys), ["index"])
    }

    func testRepeatedIntervalsAccumulate() {
        let recorder = IntervalRecorder()
        recorder.record("mutator:run", duration: .milliseconds(250))
        recorder.record("mutator:run", duration: .milliseconds(500))
        recorder.record("analyze", duration: .seconds(1))

        XCTAssertEqual(recorder.durations, ["mutator:run": .milliseconds(750), "analyze": .seconds(1)])
    }

    // MARK: - Rendering

    func testReportListsPhasesInScanOrderWithTotalAndThroughput() {
        let durations: [String: Duration] = [
            "result:output": .milliseconds(5),
            "analyze": .milliseconds(500),
            "index:swift:phase:two": .milliseconds(600),
            "index:swift:phase:one": .milliseconds(800),
            "index": .milliseconds(1500),
            "index:plan": .milliseconds(100),
            "driver:build": .seconds(10),
            "mutator:run": .milliseconds(490),
        ]
        let statistics = ScanStatistics(sourceFileCount: 12, lineCount: 4000, declarationCount: 345)

        XCTAssertEqual(
            ScanStatisticsReport.render(durations: durations, statistics: statistics),
            """
            Scan statistics:
              Build               10.000s
              Index               1.500s
                Plan              0.100s
                Swift phase one   0.800s
                Swift phase two   0.600s
              Analyze             0.500s
              Output              0.005s
              Total               12.005s
              Source files        12
              Lines of code       4000
              Throughput          2000 lines/s (index and analyze)
              Declarations        345
            """
        )
    }

    func testReportWithoutStatisticsListsOnlyTimings() {
        XCTAssertEqual(
            ScanStatisticsReport.render(durations: ["result:output": .milliseconds(2)], statistics: nil),
            """
            Scan statistics:
              Output              0.002s
              Total               0.002s
            """
        )
    }

    func testReportLeavesOutThroughputWithoutALineCount() {
        let statistics = ScanStatistics(sourceFileCount: 1, lineCount: nil, declarationCount: 2)

        XCTAssertEqual(
            ScanStatisticsReport.render(durations: ["index": .seconds(1)], statistics: statistics),
            """
            Scan statistics:
              Index               1.000s
              Total               1.000s
              Source files        1
              Declarations        2
            """
        )
    }

    // MARK: - Private

    /// Runs the real scan of the fixture package and returns what it wrote to standard output and standard error.
    private func scanFixture(_ arguments: [String]) throws -> (output: String, errorOutput: String) {
        let command = try ScanCommand.parse(["--project-root", FixturesProjectPath.string, "--skip-build", "--disable-update-check", "--quiet"] + arguments)
        var output = ""
        let errorOutput = try captureOutput(of: STDERR_FILENO) {
            output = try captureOutput(of: STDOUT_FILENO) {
                try command.run()
            }
        }
        return (output, errorOutput)
    }

    private func indexFixture(stats: Bool) throws -> Int? {
        let configuration = Configuration()
        configuration.stats = stats
        let graph = SourceGraph(configuration: configuration, logger: Self.logger)
        return try IndexPipeline(
            plan: XCTUnwrap(Self.plan),
            graph: SourceGraphMutex(graph: graph),
            logger: Self.logger.contextualized(with: "index"),
            configuration: configuration,
            swiftVersion: Self.swiftVersion
        ).perform()
    }

    private func value(of label: String, in report: [String]) throws -> Int {
        let line = try XCTUnwrap(report.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(label) }, label)
        return try XCTUnwrap(Int(line.dropFirst(label.count + 2).trimmingCharacters(in: .whitespaces)), line)
    }
}

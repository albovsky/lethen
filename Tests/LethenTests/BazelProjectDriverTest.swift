import Configuration
import Foundation
@testable import Frontend
import Logger
@testable import ProjectDrivers
import Shared
import Synchronization
import SystemPackage
import XCTest

final class BazelProjectDriverTest: XCTestCase {
    private var outputPath: FilePath!
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lethen-bazel-\(UUID().uuidString)")
        outputPath = FilePath(url.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: outputPath.string)
        try super.tearDownWithError()
    }

    func testSkipBuildIsRejectedBeforeAnyBazelCommand() {
        let configuration = Configuration()
        configuration.skipBuild = true
        let shell = RecordingShell()
        let project = Project(kind: .bazel, configuration: configuration, shell: shell, logger: logger)

        XCTAssertThrowsError(try project.driver()) { assertBazelBuildRequired($0) }
        XCTAssertEqual(shell.commands, [])
    }

    func testIndexStorePathIsRejectedBeforeAnyBazelCommand() throws {
        let configuration = Configuration()
        configuration.indexStorePath = [outputPath.appending("store")]
        XCTAssertFalse(configuration.skipBuild)
        let shell = RecordingShell()
        let project = Project(kind: .bazel, configuration: configuration, shell: shell, logger: logger)
        let scan = try Scan(configuration: configuration, logger: logger, swiftVersion: SwiftVersion(shell: VersionShell()))

        XCTAssertThrowsError(try scan.perform(project: project)) { assertBazelBuildRequired($0) }
        XCTAssertTrue(configuration.skipBuild, "Scan applies the implied '--skip-build' before creating the driver")
        XCTAssertEqual(shell.commands, [])
    }

    func testBuildQueriesTargetsThenRunsTheGeneratedScan() throws {
        let configuration = Configuration()
        let shell = RecordingShell(queryOutput: "//app:app\n//lib:tests", runStatus: 3)
        let project = Project(kind: .bazel, configuration: configuration, shell: shell, logger: logger)
        XCTAssertTrue(try project.driver() is BazelProjectDriver)
        XCTAssertEqual(shell.commands, [], "Creating the driver runs nothing")

        let driver = BazelProjectDriver(
            configuration: configuration,
            shell: shell,
            logger: logger,
            fileManager: .default,
            outputPath: outputPath
        )

        XCTAssertEqual(try driver.buildAndScan(), 3, "The scan's exit status is returned for the CLI to exit with")
        XCTAssertEqual(shell.commands.count, 2)
        XCTAssertEqual(shell.commands.first?.prefix(2), ["bazel", "query"])
        XCTAssertEqual(shell.commands.last, [
            "bazel",
            "run",
            "--check_visibility=false",
            "--ui_event_filters=-info,-debug,-warning",
            "@periphery_generated//:scan",
        ])
        let buildFile = try String(contentsOfFile: outputPath.appending("BUILD.bazel").string, encoding: .utf8)
        XCTAssertTrue(buildFile.contains("\"@@//app:app\""), buildFile)
        XCTAssertTrue(buildFile.contains("\"@@//lib:tests\""), buildFile)
    }

    // MARK: - Private

    private func assertBazelBuildRequired(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case let LethenError.usageError(message) = error else {
            return XCTFail("Expected a usage error, got: \(error)", file: file, line: line)
        }

        XCTAssertTrue(message.contains("Bazel"), message, file: file, line: line)
        XCTAssertTrue(message.contains("--generic-project-config"), message, file: file, line: line)
    }

    /// Records each command's arguments and answers `bazel query` with canned output.
    private final class RecordingShell: Shell {
        private let recorded = Mutex<[[String]]>([])
        private let queryOutput: String
        private let runStatus: Int32

        init(queryOutput: String = "", runStatus: Int32 = 0) {
            self.queryOutput = queryOutput
            self.runStatus = runStatus
        }

        var commands: [[String]] {
            recorded.withLock { $0 }
        }

        func exec(_ args: [String]) throws -> String {
            recorded.withLock { $0.append(args) }
            return args.prefix(2) == ["bazel", "query"] ? queryOutput : ""
        }

        func execStatus(_ args: [String]) throws -> Int32 {
            recorded.withLock { $0.append(args) }
            return runStatus
        }
    }

    private struct VersionShell: Shell {
        func exec(_: [String]) throws -> String {
            "Swift version 6.3 (swift-6.3-RELEASE)"
        }

        func execStatus(_: [String]) throws -> Int32 {
            0
        }
    }
}

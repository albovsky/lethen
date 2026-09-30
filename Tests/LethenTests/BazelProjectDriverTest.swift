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
    /// Stands in for Bazel's output base, which `bazel info output_base` reports.
    private var outputBase: FilePath!
    private var generatedDirectory: FilePath!
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lethen-bazel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        outputBase = FilePath(url.path)
        generatedDirectory = outputBase.appending("lethen_generated")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: outputBase.string)
        try super.tearDownWithError()
    }

    // MARK: - Build requirement

    func testSkipBuildIsRejectedBeforeAnyBazelCommand() {
        let configuration = Configuration()
        configuration.skipBuild = true
        let shell = RecordingShell(outputBase: outputBase)
        let project = Project(kind: .bazel, configuration: configuration, shell: shell, logger: logger)

        XCTAssertThrowsError(try project.driver()) { assertBazelBuildRequired($0) }
        XCTAssertEqual(shell.commands, [])
    }

    func testIndexStorePathIsRejectedBeforeAnyBazelCommand() throws {
        let configuration = Configuration()
        configuration.indexStorePath = [outputBase.appending("store")]
        XCTAssertFalse(configuration.skipBuild)
        let shell = RecordingShell(outputBase: outputBase)
        let project = Project(kind: .bazel, configuration: configuration, shell: shell, logger: logger)
        let scan = try Scan(configuration: configuration, logger: logger, swiftVersion: SwiftVersion(shell: VersionShell()))

        XCTAssertThrowsError(try scan.perform(project: project)) { assertBazelBuildRequired($0) }
        XCTAssertTrue(configuration.skipBuild, "Scan applies the implied '--skip-build' before creating the driver")
        XCTAssertEqual(shell.commands, [])
    }

    func testBuildQueriesTargetsThenRunsTheGeneratedScan() throws {
        let configuration = Configuration()
        let shell = RecordingShell(outputBase: outputBase, queryOutput: "//app:app\n//lib:tests", runStatus: 3)
        let project = Project(kind: .bazel, configuration: configuration, shell: shell, logger: logger)
        XCTAssertTrue(try project.driver() is BazelProjectDriver)
        XCTAssertEqual(shell.commands, [], "Creating the driver runs nothing")

        let driver = makeDriver(configuration: configuration, shell: shell)

        XCTAssertEqual(try driver.buildAndScan(), 3, "The scan's exit status is returned for the CLI to exit with")
        XCTAssertEqual(shell.commands.count, 3)
        XCTAssertEqual(shell.commands.first, ["bazel", "info", "output_base"])
        XCTAssertEqual(shell.commands.dropFirst().first?.prefix(2), ["bazel", "query"])
        XCTAssertEqual(shell.commands.last, [
            "bazel",
            "run",
            "--check_visibility=false",
            "--ui_event_filters=-info,-debug,-warning",
            "--repo_env=LETHEN_BAZEL_GENERATED_DIR=\(generatedDirectory!)",
            "@periphery_generated//:scan",
        ])
        let buildFile = try String(contentsOfFile: generatedDirectory.appending("BUILD.bazel").string, encoding: .utf8)
        XCTAssertTrue(buildFile.contains("\"@@//app:app\""), buildFile)
        XCTAssertTrue(buildFile.contains("\"@@//lib:tests\""), buildFile)
    }

    // MARK: - Generated directory

    func testGeneratedFilesAreWrittenToAPrivateDirectoryInTheOutputBase() throws {
        let shell = RecordingShell(outputBase: outputBase)

        XCTAssertEqual(try makeDriver(shell: shell).buildAndScan(), 0)

        let status = try XCTUnwrap(FileStatus.read(generatedDirectory))
        XCTAssertTrue(status.isDirectory)
        XCTAssertEqual(status.ownerID, geteuid())
        XCTAssertEqual(status.mode & 0o777, 0o700)
        XCTAssertEqual(try contents(of: generatedDirectory), ["BUILD.bazel", "periphery.yml"])
        let buildFile = try String(contentsOfFile: generatedDirectory.appending("BUILD.bazel").string, encoding: .utf8)
        XCTAssertTrue(buildFile.contains("config = \"\(generatedDirectory.appending("periphery.yml"))\""), buildFile)
    }

    func testExistingPrivateDirectoryIsReused() throws {
        XCTAssertEqual(mkdir(generatedDirectory.string, 0o700), 0)
        try "stale".write(toFile: generatedDirectory.appending("BUILD.bazel").string, atomically: true, encoding: .utf8)
        let shell = RecordingShell(outputBase: outputBase)

        XCTAssertEqual(try makeDriver(shell: shell).buildAndScan(), 0)

        let buildFile = try String(contentsOfFile: generatedDirectory.appending("BUILD.bazel").string, encoding: .utf8)
        XCTAssertTrue(buildFile.contains("scan("), buildFile)
        XCTAssertEqual(shell.commands.last?.prefix(2), ["bazel", "run"])
    }

    func testSymbolicLinkInPlaceOfTheDirectoryIsRejected() throws {
        let target = outputBase.appending("elsewhere")
        XCTAssertEqual(mkdir(target.string, 0o700), 0)
        try FileManager.default.createSymbolicLink(atPath: generatedDirectory.string, withDestinationPath: target.string)
        let shell = RecordingShell(outputBase: outputBase)

        XCTAssertThrowsError(try makeDriver(shell: shell).buildAndScan()) {
            assertUnsafeDirectory($0, reason: "symbolic link")
        }
        XCTAssertEqual(try contents(of: target), [], "Nothing is written through the link")
        XCTAssertEqual(shell.commands, [["bazel", "info", "output_base"]])
    }

    func testDirectoryWritableByOthersIsRejected() throws {
        XCTAssertEqual(mkdir(generatedDirectory.string, 0o700), 0)
        XCTAssertEqual(chmod(generatedDirectory.string, 0o777), 0)
        let shell = RecordingShell(outputBase: outputBase)

        XCTAssertThrowsError(try makeDriver(shell: shell).buildAndScan()) {
            assertUnsafeDirectory($0, reason: "mode 777")
        }
        XCTAssertEqual(try contents(of: generatedDirectory), [])
        XCTAssertEqual(shell.commands, [["bazel", "info", "output_base"]])
    }

    func testDirectoryOwnedByAnotherUserIsRejected() throws {
        XCTAssertEqual(mkdir(generatedDirectory.string, 0o700), 0)
        let shell = RecordingShell(outputBase: outputBase)
        let otherUserID = geteuid() &+ 1
        let driver = makeDriver(shell: shell) { path in
            try FileStatus.read(path).map { FileStatus(mode: $0.mode, ownerID: otherUserID) }
        }

        XCTAssertThrowsError(try driver.buildAndScan()) {
            assertUnsafeDirectory($0, reason: "owned by user ID \(otherUserID)")
        }
        XCTAssertEqual(try contents(of: generatedDirectory), [])
        XCTAssertEqual(shell.commands, [["bazel", "info", "output_base"]])
    }

    // MARK: - Private

    private func makeDriver(
        configuration: Configuration = Configuration(),
        shell: RecordingShell,
        fileStatus: @escaping (FilePath) throws -> FileStatus? = FileStatus.read
    ) -> BazelProjectDriver {
        BazelProjectDriver(configuration: configuration, shell: shell, logger: logger, fileStatus: fileStatus)
    }

    private func contents(of directory: FilePath) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.string).sorted()
    }

    private func assertBazelBuildRequired(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case let LethenError.usageError(message) = error else {
            return XCTFail("Expected a usage error, got: \(error)", file: file, line: line)
        }

        XCTAssertTrue(message.contains("Bazel"), message, file: file, line: line)
        XCTAssertTrue(message.contains("--generic-project-config"), message, file: file, line: line)
    }

    private func assertUnsafeDirectory(
        _ error: Error,
        reason expectedReason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let LethenError.unsafeDirectory(path, reason) = error else {
            return XCTFail("Expected an unsafe directory error, got: \(error)", file: file, line: line)
        }

        XCTAssertEqual(path, generatedDirectory, file: file, line: line)
        XCTAssertTrue(reason.contains(expectedReason), reason, file: file, line: line)
    }

    /// Records each command's arguments and answers `bazel info output_base` and `bazel query` with canned output.
    private final class RecordingShell: Shell {
        private let recorded = Mutex<[[String]]>([])
        private let outputBase: FilePath
        private let queryOutput: String
        private let runStatus: Int32

        init(outputBase: FilePath, queryOutput: String = "//app:app", runStatus: Int32 = 0) {
            self.outputBase = outputBase
            self.queryOutput = queryOutput
            self.runStatus = runStatus
        }

        var commands: [[String]] {
            recorded.withLock { $0 }
        }

        func exec(_ args: [String]) throws -> String {
            recorded.withLock { $0.append(args) }

            switch Array(args.prefix(2)) {
            case ["bazel", "info"]:
                return "\(outputBase)\n"
            case ["bazel", "query"]:
                return queryOutput
            default:
                return ""
            }
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

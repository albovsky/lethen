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
        XCTAssertEqual(shell.commands.count, 4)
        XCTAssertEqual(shell.commands.first, ["bazel", "info", "output_base"])
        XCTAssertEqual(shell.commands.dropFirst().first?.prefix(2), ["bazel", "query"])
        XCTAssertEqual(shell.commands.dropFirst(2).first, markerQuery)
        XCTAssertEqual(shell.commands.last, [
            "bazel",
            "run",
            "--check_visibility=false",
            "--ui_event_filters=-info,-debug,-warning",
            "--repo_env=LETHEN_BAZEL_GENERATED_DIR=\(generatedDirectory!)",
            "@periphery_generated//lethen_scan:scan",
        ])
        let buildFile = try String(contentsOfFile: generatedDirectory.appending("BUILD.bazel").string, encoding: .utf8)
        XCTAssertTrue(buildFile.contains("\"@@//app:app\""), buildFile)
        XCTAssertTrue(buildFile.contains("\"@@//lib:tests\""), buildFile)
    }

    /// The private directory's `--repo_env` comes after the build arguments, since Bazel uses the last one.
    func testRepositoryEnvironmentFollowsTheBuildArguments() throws {
        let configuration = Configuration()
        configuration.buildArguments = ["--config=ci", "--repo_env=OTHER=1"]
        // Other repositories may still be overridden.
        configuration.buildArguments += ["--override_repository=rules_swift=/local/rules_swift"]
        let shell = RecordingShell(outputBase: outputBase)

        XCTAssertEqual(try makeDriver(configuration: configuration, shell: shell).buildAndScan(), 0)

        let run = try XCTUnwrap(shell.commands.last)
        XCTAssertEqual(Array(run.suffix(5)), [
            "--config=ci",
            "--repo_env=OTHER=1",
            "--override_repository=rules_swift=/local/rules_swift",
            "--repo_env=LETHEN_BAZEL_GENERATED_DIR=\(generatedDirectory!)",
            "@periphery_generated//lethen_scan:scan",
        ])
    }

    /// Build arguments may not point the generated repository somewhere else, by its variable or by overriding it.
    func testBuildArgumentsSettingTheGeneratedDirectoryAreRejected() throws {
        for arguments in [
            ["--repo_env=LETHEN_BAZEL_GENERATED_DIR=/elsewhere"],
            ["--repo_env", "LETHEN_BAZEL_GENERATED_DIR=/elsewhere"],
            ["--repo_env=LETHEN_BAZEL_GENERATED_DIR"],
            ["--override_repository=periphery_generated=/elsewhere"],
            ["--override_repository", "+generated+periphery_generated=/elsewhere"],
            ["--override_repository=@@periphery++generated+periphery_generated=/elsewhere"],
        ] {
            let configuration = Configuration()
            configuration.buildArguments = arguments
            let shell = RecordingShell(outputBase: outputBase)

            XCTAssertThrowsError(try makeDriver(configuration: configuration, shell: shell).buildAndScan(), "\(arguments)") { error in
                guard case let LethenError.usageError(message) = error else {
                    return XCTFail("Expected a usage error, got: \(error)")
                }

                XCTAssertTrue(message.contains("LETHEN_BAZEL_GENERATED_DIR") || message.contains("periphery_generated"), message)
            }
            XCTAssertEqual(shell.commands, [], "Nothing runs for \(arguments)")
        }
    }

    func testOlderPeripheryModuleStopsTheScanBeforeBazelRun() throws {
        let shell = RecordingShell(outputBase: outputBase, markerQueryFails: true)

        XCTAssertThrowsError(try makeDriver(shell: shell).buildAndScan()) { error in
            guard case let LethenError.usageError(message) = error else {
                return XCTFail("Expected a usage error, got: \(error)")
            }

            XCTAssertTrue(message.contains("'periphery' Bazel module is older than this lethen binary"), message)
            XCTAssertTrue(message.contains("no such package"), "Bazel's output is included: \(message)")
        }
        XCTAssertEqual(shell.commands.last, markerQuery)
        XCTAssertFalse(shell.commands.contains { $0.prefix(2) == ["bazel", "run"] }, "\(shell.commands)")
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

    /// Values in the generated BUILD file are Starlark string literals, so an output base or index store path with a
    /// quote or backslash stays one exact string instead of breaking the file.
    func testGeneratedBuildFileQuotesPathsWithQuotesAndBackslashes() throws {
        let unusual = outputBase.appending("base \"quoted\" back\\slash")
        XCTAssertEqual(mkdir(unusual.string, 0o700), 0)
        let generated = unusual.appending("lethen_generated")
        let configuration = Configuration()
        configuration.bazelIndexStore = unusual.appending("index \"store\"")
        let shell = RecordingShell(outputBase: unusual, queryOutput: "//app:app")

        XCTAssertEqual(try makeDriver(configuration: configuration, shell: shell).buildAndScan(), 0)

        let buildFile = try String(contentsOfFile: generated.appending("BUILD.bazel").string, encoding: .utf8)
        XCTAssertTrue(buildFile.contains(#"config = "\#(outputBase.string)/base \"quoted\" back\\slash/lethen_generated/periphery.yml","#), buildFile)
        XCTAssertTrue(buildFile.contains(#"global_indexstore = "\#(outputBase.string)/base \"quoted\" back\\slash/index \"store\"","#), buildFile)
        XCTAssertTrue(buildFile.contains(#""@@//app:app""#), buildFile)
    }

    /// Bazel's output ends in a newline, which is removed; a space or tab that ends the output base itself stays.
    func testOutputBaseEndingInWhitespaceIsKept() throws {
        let unusual = outputBase.appending("base ending in space \t ")
        XCTAssertEqual(mkdir(unusual.string, 0o700), 0)
        let shell = RecordingShell(outputBase: unusual)

        XCTAssertEqual(try makeDriver(shell: shell).buildAndScan(), 0)

        let generated = unusual.appending("lethen_generated")
        XCTAssertTrue(generated.appending("BUILD.bazel").exists)
        XCTAssertTrue(shell.commands.contains { $0.contains("--repo_env=LETHEN_BAZEL_GENERATED_DIR=\(generated)") })
    }

    /// A carriage return that ends the output base's name is part of the name, not of Bazel's line terminator.
    func testOutputBaseEndingInACarriageReturnIsKept() throws {
        let unusual = outputBase.appending("base\r")
        XCTAssertEqual(mkdir(unusual.string, 0o700), 0)
        let shell = RecordingShell(outputBase: unusual)

        XCTAssertEqual(try makeDriver(shell: shell).buildAndScan(), 0)

        XCTAssertTrue(unusual.appending("lethen_generated/BUILD.bazel").exists)
        XCTAssertFalse(outputBase.appending("base/lethen_generated").exists)
    }

    func testStarlarkStringEscapesOnlyWhatStarlarkInterprets() {
        XCTAssertEqual(BazelProjectDriver.starlarkString("/plain/path with spaces/$(x)'s"), #""/plain/path with spaces/$(x)'s""#)
        XCTAssertEqual(BazelProjectDriver.starlarkString("a\"b\\c\nd\re\tf"), #""a\"b\\c\nd\re\tf""#)
        XCTAssertEqual(BazelProjectDriver.starlarkString(""), #""""#)
    }

    /// A directory only the user can change but others can read or enter is made private again before files go in.
    func testDirectoryReadableByOthersIsMadePrivate() throws {
        for mode: mode_t in [0o755, 0o711, 0o750] {
            XCTAssertEqual(mkdir(generatedDirectory.string, 0o700), 0)
            XCTAssertEqual(chmod(generatedDirectory.string, mode), 0)

            XCTAssertEqual(try makeDriver(shell: RecordingShell(outputBase: outputBase)).buildAndScan(), 0)

            let status = try XCTUnwrap(FileStatus.read(generatedDirectory))
            XCTAssertEqual(status.mode & 0o777, 0o700, "mode \(String(mode, radix: 8))")
            XCTAssertEqual(try contents(of: generatedDirectory), ["BUILD.bazel", "periphery.yml"])
            try FileManager.default.removeItem(atPath: generatedDirectory.string)
        }
    }

    /// Two scans of one workspace share the generated directory, so the lock is held from before the files are written
    /// until `bazel run` returns, and a second scan waits for it.
    func testScanHoldsTheWorkspaceLockThroughBazelRun() throws {
        let lockPath = outputBase.appending("lethen_generated.lock")
        let shell = RecordingShell(outputBase: outputBase)

        XCTAssertEqual(try makeDriver(shell: shell).buildAndScan(), 0)

        XCTAssertEqual(shell.lockWasHeldDuringRun, true)
        XCTAssertTrue(RecordingShell.canLock(lockPath), "The lock must be released once the scan returns")
    }

    func testScanWaitsWhileAnotherScanHoldsTheLock() throws {
        let lockPath = outputBase.appending("lethen_generated.lock")
        let held = open(lockPath.string, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(held, 0)
        XCTAssertEqual(flock(held, LOCK_EX), 0)
        let shell = RecordingShell(outputBase: outputBase)
        let driver = makeDriver(shell: shell)
        let finished = expectation(description: "scan finished")

        DispatchQueue.global().async {
            XCTAssertEqual(try? driver.buildAndScan(), 0)
            finished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Only the output base was looked up: nothing is written or queried while the other scan holds the lock.
        XCTAssertEqual(shell.commands, [["bazel", "info", "output_base"]])
        XCTAssertFalse(generatedDirectory.appending("BUILD.bazel").exists)

        close(held)
        wait(for: [finished], timeout: 10)
        XCTAssertEqual(shell.commands.last?.prefix(2), ["bazel", "run"])
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

    private var markerQuery: [String] {
        [
            "bazel",
            "query",
            "--repo_env=LETHEN_BAZEL_GENERATED_DIR=\(generatedDirectory!)",
            "@periphery_generated//lethen_scratch:v1",
        ]
    }

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
        private let markerQueryFails: Bool

        init(outputBase: FilePath, queryOutput: String = "//app:app", runStatus: Int32 = 0, markerQueryFails: Bool = false) {
            self.outputBase = outputBase
            self.queryOutput = queryOutput
            self.runStatus = runStatus
            self.markerQueryFails = markerQueryFails
        }

        var commands: [[String]] {
            recorded.withLock { $0 }
        }

        func exec(_ args: [String]) throws -> String {
            recorded.withLock { $0.append(args) }

            switch Array(args.prefix(2)) {
            case ["bazel", "info"]:
                return "\(outputBase)\n"
            case ["bazel", "query"] where args.last == "@periphery_generated//lethen_scratch:v1":
                guard !markerQueryFails else {
                    throw LethenError.shellCommandFailed(
                        cmd: args,
                        status: 7,
                        output: "ERROR: no such package '@@periphery++generated+periphery_generated//lethen_scratch'"
                    )
                }

                return "@periphery_generated//lethen_scratch:v1\n"
            case ["bazel", "query"]:
                return queryOutput
            default:
                return ""
            }
        }

        func execStatus(_ args: [String]) throws -> Int32 {
            recorded.withLock { $0.append(args) }
            lockedDuringRun.withLock { $0 = !Self.canLock(outputBase.appending("lethen_generated.lock")) }
            return runStatus
        }

        /// Whether the workspace lock was held by the scan when `bazel run` started.
        var lockWasHeldDuringRun: Bool? {
            lockedDuringRun.withLock { $0 }
        }

        private let lockedDuringRun = Mutex<Bool?>(nil)

        /// Whether a new descriptor can take the lock now; another descriptor's lock blocks it, even in this process.
        static func canLock(_ path: FilePath) -> Bool {
            let descriptor = open(path.string, O_RDWR | O_CREAT, 0o600)
            guard descriptor >= 0 else { return false }

            defer { close(descriptor) }
            return flock(descriptor, LOCK_EX | LOCK_NB) == 0
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

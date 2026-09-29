@testable import Configuration
import Foundation
@testable import Frontend
import Logger
@testable import PeripheryKit
import Shared
@testable import SourceGraph
import SystemPackage
import XCTest

final class ScanCommandPipelineTest: XCTestCase {
    private var originalDirectory: FilePath!
    private var projectRoot: FilePath!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDirectory = FilePath.current
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lethen-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        projectRoot = FilePath(url.path)
        StubScan.reset()
    }

    override func tearDownWithError() throws {
        _ = FileManager.default.changeCurrentDirectoryPath(originalDirectory.string)
        try? FileManager.default.removeItem(atPath: projectRoot.string)
        try super.tearDownWithError()
    }

    // MARK: - Stubbed scan

    func testScanResultsFlowThroughTheReport() throws {
        try makePackage()
        StubScan.results = [result("Foo", line: 2), result("Bar", line: 1)]
        let resultsPath = projectRoot.appending("results.json")

        let output = try captureOutput(of: STDOUT_FILENO) {
            try run(["--format", "json", "--write-results", resultsPath.string, "--disable-update-check", "--quiet"])
        }

        XCTAssertEqual(StubScan.configurations.count, 1)
        guard case .spm = try XCTUnwrap(StubScan.projectKinds.first) else {
            return XCTFail("Expected a Swift package, got: \(StubScan.projectKinds)")
        }

        let written = try String(contentsOfFile: resultsPath.string, encoding: .utf8)
        let names = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(written.utf8)) as? [[String: Any]]).compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["Bar", "Foo"])
        XCTAssertEqual(output, written + "\n")
    }

    func testStrictModeFailsWithResults() throws {
        try makePackage()
        StubScan.results = [result("Foo", line: 2), result("Bar", line: 1)]

        XCTAssertThrowsError(try captureOutput(of: STDOUT_FILENO) {
            try run(["--strict", "--format", "json", "--disable-update-check", "--quiet"])
        }) { error in
            guard case let .foundIssues(count) = error as? LethenError else {
                return XCTFail("Expected foundIssues, got: \(error)")
            }

            XCTAssertEqual(count, 2)
        }
    }

    func testStrictModePassesWithoutResults() throws {
        try makePackage()

        XCTAssertNoThrow(try captureOutput(of: STDOUT_FILENO) {
            try run(["--strict", "--format", "json", "--disable-update-check", "--quiet"])
        })
    }

    func testDisabledUpdateCheckMakesNoRequest() throws {
        try makePackage()
        let startedChecks = UpdateChecker.retainedUntilExit.withLock(\.count)

        _ = try captureOutput(of: STDOUT_FILENO) {
            try run(["--disable-update-check", "--quiet"])
        }

        XCTAssertEqual(UpdateChecker.retainedUntilExit.withLock(\.count), startedChecks)
        XCTAssertEqual(StubScan.configurations.count, 1)
    }

    func testUpdateCheckIsEnabledOnlyForXcodeFormatWithoutTheOption() throws {
        XCTAssertTrue(try updateChecker([]).isEnabled)
        XCTAssertFalse(try updateChecker(["--disable-update-check"]).isEnabled)
        XCTAssertFalse(try updateChecker(["--format", "json"]).isEnabled)
    }

    // MARK: - Summary footer

    func testXcodeFormatPrintsFooterOnStandardErrorAndLeavesStandardOutputUnchanged() throws {
        try makePackage()
        StubScan.results = [result("Foo", line: 2), result("Bar", line: 1, confidence: .likely), result("Baz", line: 3)]
        var standardOutput = ""

        let standardError = try captureOutput(of: STDERR_FILENO) {
            standardOutput = try captureOutput(of: STDOUT_FILENO) {
                try run(["--disable-update-check"])
            }
        }

        // Absolute paths: on macOS the temporary directory is reached through a symlink, so paths
        // relative to the resolved working directory climb out of it.
        let file = projectRoot.appending("Sources/A.swift").string
        XCTAssertEqual(standardOutput, """

        \(file):2:1: warning: Unused class 'Foo'
        \(file):3:1: warning: Unused class 'Baz'
        \(file):1:1: warning: Unused class 'Bar'

        """)
        XCTAssertEqual(standardError, "3 results, 1 likely. `lethen explain <name>` shows why; `--write-baseline baseline.json` records these so the next scan reports only new ones.\n")
    }

    func testFooterFoldsInResultsHiddenByMinimumConfidence() throws {
        try makePackage()
        StubScan.results = [result("Foo", line: 2), result("Bar", line: 1, confidence: .likely), result("Baz", line: 3, confidence: .likely)]

        let standardError = try captureOutput(of: STDERR_FILENO) {
            _ = try captureOutput(of: STDOUT_FILENO) {
                try run(["--min-confidence", "certain", "--disable-update-check"])
            }
        }

        XCTAssertEqual(standardError, "1 result; --min-confidence certain hid 2 results. `lethen explain <name>` shows why; `--write-baseline baseline.json` records these so the next scan reports only new ones.\n")
    }

    func testFooterIsOnlyTheMinimumConfidenceNoteWhenEveryResultIsHidden() throws {
        try makePackage()
        StubScan.results = [result("Bar", line: 1, confidence: .likely)]

        let standardError = try captureOutput(of: STDERR_FILENO) {
            _ = try captureOutput(of: STDOUT_FILENO) {
                try run(["--min-confidence", "certain", "--disable-update-check"])
            }
        }

        XCTAssertEqual(standardError, "--min-confidence certain hid 1 result.\n")
    }

    func testFooterIsAbsentWithoutResults() throws {
        try makePackage()

        let standardError = try captureOutput(of: STDERR_FILENO) {
            _ = try captureOutput(of: STDOUT_FILENO) {
                try run(["--disable-update-check"])
            }
        }

        XCTAssertEqual(standardError, "")
    }

    func testFooterLeavesOutTheBaselineHintWhenABaselineIsWritten() throws {
        try makePackage()
        StubScan.results = [result("Foo", line: 1)]
        let baselinePath = projectRoot.appending("baseline.json")

        let standardError = try captureOutput(of: STDERR_FILENO) {
            _ = try captureOutput(of: STDOUT_FILENO) {
                try run(["--write-baseline", baselinePath.string, "--disable-update-check"])
            }
        }

        XCTAssertEqual(standardError, "1 result. `lethen explain <name>` shows why.\n")
    }

    func testFooterIsAbsentForMachineReadableFormatsAndQuiet() throws {
        try makePackage()
        StubScan.results = [result("Foo", line: 1)]

        for arguments in [["--format", "json"], ["--format", "csv"], ["--format", "checkstyle"], ["--quiet"]] {
            let standardError = try captureOutput(of: STDERR_FILENO) {
                _ = try captureOutput(of: STDOUT_FILENO) {
                    try run(arguments + ["--disable-update-check"])
                }
            }

            XCTAssertEqual(standardError, "", "\(arguments)")
        }
    }

    /// Control: without the footer, `--min-confidence` still says on standard error what it hid.
    func testMachineReadableFormatsKeepTheMinimumConfidenceNote() throws {
        try makePackage()
        StubScan.results = [result("Foo", line: 2), result("Bar", line: 1, confidence: .likely)]
        var standardOutput = ""

        let standardError = try captureOutput(of: STDERR_FILENO) {
            standardOutput = try captureOutput(of: STDOUT_FILENO) {
                try run(["--format", "json", "--min-confidence", "certain", "--disable-update-check"])
            }
        }

        XCTAssertEqual(standardError, "--min-confidence certain hid 1 result.\n")
        XCTAssertFalse(standardOutput.contains("--min-confidence"), standardOutput)
    }

    func testVerboseXcodeFormatPrintsTheReasonUnderEachResult() throws {
        try makePackage()
        StubScan.results = [result("Foo", line: 1, reason: "no references in the scanned modules")]

        let standardOutput = try captureOutput(of: STDOUT_FILENO) {
            try run(["--disable-update-check", "--verbose"])
        }

        XCTAssertTrue(standardOutput.contains("""
        \(projectRoot.appending("Sources/A.swift").string):1:1: warning: Unused class 'Foo'
            reason: no references in the scanned modules

        """), standardOutput)
    }

    // MARK: - Working directory

    func testWorkingDirectoryIsRestoredAfterScan() throws {
        try makePackage()

        _ = try captureOutput(of: STDOUT_FILENO) {
            try run(["--format", "json", "--disable-update-check", "--quiet"])
        }

        XCTAssertEqual(FilePath.current, originalDirectory)
    }

    func testWorkingDirectoryIsRestoredWhenTheCommandThrows() throws {
        XCTAssertThrowsError(try run(["--disable-update-check", "--quiet"]))
        XCTAssertEqual(FilePath.current, originalDirectory)
    }

    // MARK: - Error paths

    func testMissingProjectRootIsAnError() {
        let missing = projectRoot.appending("missing")

        XCTAssertThrowsError(try ScanCommand.parse(["--project-root", missing.string]).run(scanning: StubScan.self, readInput: { nil })) { error in
            guard case .changeCurrentDirectoryFailed = error as? LethenError else {
                return XCTFail("Expected changeCurrentDirectoryFailed, got: \(error)")
            }
        }
        XCTAssertTrue(StubScan.configurations.isEmpty)
    }

    func testDirectoryWithoutProjectIsAUsageError() {
        XCTAssertThrowsError(try run(["--disable-update-check", "--quiet"])) { error in
            guard case let .usageError(message) = error as? LethenError else {
                return XCTFail("Expected a usage error, got: \(error)")
            }

            XCTAssertTrue(message.hasPrefix("Failed to identify project in the current directory."), message)
        }
        XCTAssertTrue(StubScan.configurations.isEmpty)
    }

    func testXcodeProjectInTheCurrentDirectoryIsDetected() throws {
        try makeXcodeProject("App.xcodeproj")

        try run(["--disable-update-check", "--quiet"])

        guard case let .xcode(projectPath) = try XCTUnwrap(StubScan.projectKinds.first) else {
            return XCTFail("Expected an Xcode project, got: \(StubScan.projectKinds)")
        }

        XCTAssertEqual(projectPath.lastComponent?.string, "App.xcodeproj")
    }

    func testExplicitProjectWinsOverAmbiguousDetection() throws {
        try makeXcodeProject("App.xcodeproj")
        try makeXcodeProject("Tool.xcodeproj")

        try run(["--project", "Tool.xcodeproj", "--disable-update-check", "--quiet"])

        guard case let .xcode(projectPath) = try XCTUnwrap(StubScan.projectKinds.first) else {
            return XCTFail("Expected an Xcode project, got: \(StubScan.projectKinds)")
        }

        XCTAssertEqual(projectPath, "Tool.xcodeproj")
    }

    func testAmbiguousProjectsAreAUsageErrorListingTheOptions() throws {
        try makeXcodeProject("App.xcodeproj")
        try makeXcodeProject("Tool.xcodeproj")

        XCTAssertThrowsError(try run(["--disable-update-check", "--quiet"])) { error in
            guard case let .usageError(message) = error as? LethenError else {
                return XCTFail("Expected a usage error, got: \(error)")
            }

            XCTAssertTrue(message.contains("\n  --project App.xcodeproj\n  --project Tool.xcodeproj"), message)
        }
        XCTAssertTrue(StubScan.configurations.isEmpty)
    }

    #if !os(macOS)
        func testXcodeProjectIsAUsageErrorOffMacOS() throws {
            let command = try ScanCommand.parse(["--project-root", projectRoot.string, "--project", "App.xcodeproj", "--disable-update-check", "--quiet"])

            XCTAssertThrowsError(try command.run(scanning: Scan.self, readInput: { nil })) { error in
                guard case let .usageError(message) = error as? LethenError else {
                    return XCTFail("Expected a usage error, got: \(error)")
                }

                XCTAssertTrue(message.hasPrefix("Xcode projects are only supported on macOS."), message)
            }
        }
    #endif

    // MARK: - Guided setup

    func testGuidedSetupFailsWhenInputEnds() throws {
        try makePackage()

        let output = try captureOutput(of: STDOUT_FILENO) {
            XCTAssertThrowsError(try run(["--setup", "--disable-update-check"], input: [])) { error in
                guard case let .guidedSetupError(message) = error as? LethenError else {
                    return XCTFail("Expected a guided setup error, got: \(error)")
                }

                XCTAssertTrue(message.hasPrefix("Input ended before a choice was made"), message)
            }
        }

        XCTAssertTrue(output.contains("Assume all 'public' declarations are in use?"), output)
        XCTAssertTrue(StubScan.configurations.isEmpty)
    }

    func testGuidedSetupAppliesAnswersThenScans() throws {
        try makePackage()

        let output = try captureOutput(of: STDOUT_FILENO) {
            // Retain public declarations, then decline to save the configuration.
            try run(["--setup", "--disable-update-check", "--format", "json"], input: ["y", "n"])
        }

        XCTAssertTrue(output.contains("Detected Swift Package project"), output)
        XCTAssertTrue(try XCTUnwrap(StubScan.configurations.first).retainPublic)
        XCTAssertFalse(projectRoot.appending(".periphery.yml").exists)
    }

    func testGuidedSetupWithoutProjectIsAnError() throws {
        _ = try captureOutput(of: STDOUT_FILENO) {
            XCTAssertThrowsError(try run(["--setup", "--disable-update-check"], input: ["y"])) { error in
                guard case let .guidedSetupError(message) = error as? LethenError else {
                    return XCTFail("Expected a guided setup error, got: \(error)")
                }

                XCTAssertTrue(message.hasPrefix("Failed to identify a project in the current directory"), message)
            }
        }
        XCTAssertTrue(StubScan.configurations.isEmpty)
    }

    // MARK: - Private

    private final class StubScan: ScanRunning {
        static var results: [ScanResult] = []
        static var configurations: [Configuration] = []
        static var projectKinds: [ProjectKind] = []

        static func reset() {
            results = []
            configurations = []
            projectKinds = []
        }

        init(configuration: Configuration, logger _: Logger, swiftVersion _: SwiftVersion) {
            Self.configurations.append(configuration)
        }

        func perform(project: Project) throws -> Scan.Output {
            Self.projectKinds.append(project.kind)
            return Scan.Output(results: Self.results)
        }
    }

    private func run(_ arguments: [String], input: [String] = []) throws {
        var remaining = input
        let command = try ScanCommand.parse(["--project-root", projectRoot.string] + arguments)
        try command.run(scanning: StubScan.self, readInput: { remaining.isEmpty ? nil : remaining.removeFirst() })
    }

    private func updateChecker(_ arguments: [String]) throws -> UpdateChecker {
        let configuration = try ScanCommand.parse(["--project-root", projectRoot.string] + arguments).makeConfiguration()
        return UpdateChecker(logger: Logger(quiet: true, verbose: false, colorMode: .never), configuration: configuration)
    }

    private func makePackage() throws {
        try "// swift-tools-version:6.0\n".write(toFile: projectRoot.appending("Package.swift").string, atomically: true, encoding: .utf8)
    }

    private func makeXcodeProject(_ name: String) throws {
        let path = projectRoot.appending(name)
        try FileManager.default.createDirectory(atPath: path.string, withIntermediateDirectories: true)
        try "// !$*UTF8*$!\n{}\n".write(toFile: path.appending("project.pbxproj").string, atomically: true, encoding: .utf8)
    }

    private func result(_ name: String, line: Int, confidence: Confidence = .certain, reason: String = "") -> ScanResult {
        let location = Location(file: SourceFile(path: projectRoot.appending("Sources/A.swift"), modules: ["App"]), line: line, column: 1)
        let declaration = Declaration(name: name, kind: .class, usrs: ["s:\(name)"], location: location)
        return ScanResult(declaration: declaration, annotation: .unused, confidence: confidence, reason: reason)
    }
}

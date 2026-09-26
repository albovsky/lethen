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

    private func result(_ name: String, line: Int) -> ScanResult {
        let location = Location(file: SourceFile(path: projectRoot.appending("Sources/A.swift"), modules: ["App"]), line: line, column: 1)
        let declaration = Declaration(name: name, kind: .class, usrs: ["s:\(name)"], location: location)
        return ScanResult(declaration: declaration, annotation: .unused)
    }
}

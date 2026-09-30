import Foundation
import Logger
import Shared
import Synchronization
import SystemPackage
@testable import XcodeSupport
import XCTest

final class XcodebuildDerivedDataPathTest: XCTestCase {
    private var project: XcodeProject!
    private var shell: RecordingShell!
    private var xcodebuild: Xcodebuild!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        var loadedProjectPaths: Set<FilePath> = []
        let loadingShell = ShellImpl(logger: logger)
        let loadingXcodebuild = Xcodebuild(shell: loadingShell, logger: logger)
        project = try XcodeProject(path: UIKitProjectPath, loadedProjectPaths: &loadedProjectPaths, xcodebuild: loadingXcodebuild, shell: loadingShell, logger: logger)
        shell = RecordingShell()
        xcodebuild = Xcodebuild(shell: shell, logger: logger)
    }

    override func tearDown() {
        project = nil
        shell = nil
        xcodebuild = nil
        super.tearDown()
    }

    func testDerivedDataPathDoesNotDependOnSchemeOrder() throws {
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["B", "A"])
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A", "B"])
        let paths = shell.derivedDataPaths
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths.first, paths.last)
    }

    func testDerivedDataPathDependsOnTheSetOfSchemes() throws {
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A", "B"])
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A", "C"])
        let paths = shell.derivedDataPaths
        XCTAssertEqual(paths.count, 2)
        XCTAssertNotEqual(paths.first, paths.last)
    }

    func testNoConfigurationOrBuildArgumentsKeepsThePreviousPath() throws {
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["B", "A"])
        let version = try xcodebuild.version().djb2Hex
        let expected = try Constants.cachePath().appending("DerivedData-\(version)-\(project.name.djb2Hex)-\("AB".djb2Hex)")
        XCTAssertEqual(shell.derivedDataPaths, [expected.string])
    }

    func testDerivedDataPathDependsOnTheConfiguration() throws {
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"])
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], configuration: "Debug")
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], configuration: "Release")
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], configuration: "Release")
        let paths = shell.derivedDataPaths
        XCTAssertEqual(paths.count, 4)
        XCTAssertEqual(Set(paths.prefix(3)).count, 3, "\(paths)")
        XCTAssertEqual(paths[2], paths[3])
    }

    func testDerivedDataPathDependsOnTheBuildArguments() throws {
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"])
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], additionalArguments: ["-configuration", "Release"])
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], additionalArguments: ["-configuration", "Debug"])
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], additionalArguments: ["OTHER_SWIFT_FLAGS=-DA -DB"])
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], additionalArguments: ["OTHER_SWIFT_FLAGS=-DA", "-DB"])
        let paths = shell.derivedDataPaths
        XCTAssertEqual(paths.count, 5)
        XCTAssertEqual(Set(paths).count, 5, "\(paths)")
    }

    func testConfiguredPathDoesNotDependOnSchemeOrder() throws {
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["B", "A"], configuration: "Release")
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A", "B"], configuration: "Release")
        let paths = shell.derivedDataPaths
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths.first, paths.last)
    }

    func testIndexStoreAndRemovalUseTheBuildsPath() throws {
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"], configuration: "Release", additionalArguments: ["-destination", "platform=macOS"])
        let built = try XCTUnwrap(shell.derivedDataPaths.first)
        // The directory is removed in process, not by a command.
        try FileManager.default.createDirectory(atPath: built, withIntermediateDirectories: true)
        let commands = shell.executed.count
        try xcodebuild.removeDerivedData(for: project, allSchemes: ["A"], configuration: "Release", buildArguments: ["-destination", "platform=macOS"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: built))
        XCTAssertEqual(shell.executed.count, commands)

        XCTAssertThrowsError(try xcodebuild.indexStorePath(project: project, schemes: ["A"], configuration: "Release", buildArguments: ["-destination", "platform=macOS"])) { error in
            guard case let LethenError.indexStoreNotFound(derivedDataPath) = error else { return XCTFail("\(error)") }

            XCTAssertEqual(derivedDataPath, built)
        }
    }

    func testBuildStreamsOnlyTheBuildCommand() throws {
        let lines = Mutex<[String]>([])

        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"]) { line in lines.withLock { $0.append(line) } }

        XCTAssertEqual(shell.streamed.count, 1)
        XCTAssertEqual(shell.streamed.first?.first, "xcodebuild")
        XCTAssertEqual(shell.streamed.first?.contains("build-for-testing"), true)
        XCTAssertEqual(lines.withLock { $0 }, ["note: Building targets in dependency order"])
    }
}

import Foundation
import Logger
import Shared
import SystemPackage
@testable import XcodeSupport
import XCTest

final class XcodebuildBuildProjectTest: XCTestCase {
    private var xcodebuild: Xcodebuild!
    private var project: XcodeProject!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let shell = ShellImpl(logger: logger)
        var loadedProjectPaths: Set<FilePath> = []
        xcodebuild = Xcodebuild(shell: shell, logger: logger)
        project = try XcodeProject(path: UIKitProjectPath, loadedProjectPaths: &loadedProjectPaths, xcodebuild: xcodebuild, shell: shell, logger: logger)
    }

    override func tearDown() {
        xcodebuild = nil
        project = nil
        super.tearDown()
    }

    func testBuildSchemeWithWhitespace() throws {
        let scheme = "Scheme With Spaces"
        try xcodebuild.build(project: project, scheme: scheme, allSchemes: [scheme])
    }

    func testConfigurationIsPassedAsOneArgument() throws {
        let shell = RecordingShell()
        let recording = Xcodebuild(shell: shell, logger: Logger(quiet: true, verbose: false, colorMode: .never))
        try recording.build(project: project, scheme: "Scheme", allSchemes: ["Scheme"], configuration: "App Store")
        try recording.build(project: project, scheme: "Scheme", allSchemes: ["Scheme"])

        let commands = shell.streamed
        XCTAssertEqual(commands.count, 2)
        let configured = try XCTUnwrap(commands.first)
        let index = try XCTUnwrap(configured.firstIndex(of: "-configuration"))
        XCTAssertEqual(configured[index + 1], "App Store")
        XCTAssertEqual(configured.last { !$0.contains("=") }, "build-for-testing")
        XCTAssertFalse(try XCTUnwrap(commands.last).contains("-configuration"))
    }

    func testBuildActionPassesBuildWithoutBuildForTesting() throws {
        let shell = RecordingShell()
        let recording = Xcodebuild(shell: shell, logger: Logger(quiet: true, verbose: false, colorMode: .never))
        try recording.build(project: project, scheme: "Scheme", allSchemes: ["Scheme"], configuration: "Release", action: .build)

        let command = try XCTUnwrap(shell.streamed.first)
        XCTAssertEqual(command.last { !$0.contains("=") }, "build")
        XCTAssertFalse(command.contains("build-for-testing"))
    }
}

import Configuration
import Foundation
import Logger
@testable import ProjectDrivers
import Shared
import SystemPackage
@testable import TestShared
@testable import XcodeSupport
import XCTest

/// `--configurations` builds and scans several Xcode build configurations together. ConfigurationsProject
/// has a function called only under `#if DEBUG` and one called only without it, so a reference from either
/// configuration is visible.
final class XcodeConfigurationsTest: XcodeSourceGraphTestCase {
    // MARK: - Builds

    func testDefaultScanBuildsTheSchemesTestConfiguration() throws {
        let configuration = Self.configuration([])
        try Self.build(projectPath: ConfigurationsProjectPath, configuration: configuration)
        try Self.index(configuration: configuration)
        assertReferenced(.functionFree("calledOnlyInDebug()"))
        assertNotReferenced(.functionFree("calledOnlyInRelease()"))
    }

    func testSingleConfigurationReportsTheOtherBranchsCallee() throws {
        let configuration = Self.configuration(["Release"])
        try Self.build(projectPath: ConfigurationsProjectPath, configuration: configuration)
        try Self.index(configuration: configuration)
        assertReferenced(.functionFree("calledOnlyInRelease()"))
        assertNotReferenced(.functionFree("calledOnlyInDebug()"))
    }

    func testBothConfigurationsUnionReferences() throws {
        let configuration = Self.configuration(["Debug", "Release"])
        try Self.build(projectPath: ConfigurationsProjectPath, configuration: configuration)
        try Self.index(configuration: configuration)
        assertReferenced(.functionFree("calledOnlyInDebug()"))
        assertReferenced(.functionFree("calledOnlyInRelease()"))
    }

    // MARK: - Driver

    func testEachConfigurationBuildsIntoItsOwnDerivedData() throws {
        let shell = RecordingShell()
        let driver = try Self.recordingDriver(Self.configuration(["Debug", "Release", "Debug"]), shell: shell)

        try driver.build()

        let builds = shell.streamed
        let configurations = try builds.map { command in
            let index = try XCTUnwrap(command.firstIndex(of: "-configuration"))
            return command[index + 1]
        }
        XCTAssertEqual(configurations, ["\"Debug\"", "\"Release\""])
        XCTAssertTrue(builds.allSatisfy { $0.contains("build-for-testing") })
        XCTAssertEqual(Set(shell.derivedDataPaths).count, 2, "\(shell.derivedDataPaths)")
    }

    func testCleanBuildRemovesEveryConfigurationsDerivedData() throws {
        let shell = RecordingShell()
        let configuration = Self.configuration(["Debug", "Release"])
        configuration.cleanBuild = true
        let driver = try Self.recordingDriver(configuration, shell: shell)

        try driver.build()

        let removed = shell.executed.filter { $0.first == "rm" }.map { "'\($0[2])'" }
        XCTAssertEqual(removed.count, 2)
        XCTAssertEqual(Set(removed), Set(shell.derivedDataPaths))
    }

    /// A configuration that does not build fails the scan; it is never retried as a plain build.
    func testFailingConfigurationBuildThrowsWithoutFallback() throws {
        let shell = RecordingShell(failingArgument: "\"Release\"")
        let driver = try Self.recordingDriver(Self.configuration(["Debug", "Release"]), shell: shell)

        XCTAssertThrowsError(try driver.build()) { error in
            guard case LethenError.shellCommandFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(shell.streamed.count, 2)
        XCTAssertTrue(shell.streamed.allSatisfy { $0.contains("-configuration") && $0.contains("build-for-testing") })
    }

    // MARK: - Validation

    func testRejectsUnknownConfiguration() {
        let configuration = Self.configuration(["Debug", "Profile"])
        XCTAssertThrowsError(try Self.driver(configuration)) { error in
            guard case let LethenError.usageError(message) = error else { return XCTFail("\(error)") }

            XCTAssertTrue(message.contains("Profile"), message)
            XCTAssertTrue(message.contains("Debug, Release"), message)
        }
    }

    func testRejectsConfigurationInBuildArguments() {
        let configuration = Self.configuration(["Debug"])
        configuration.buildArguments = ["-configuration", "Release"]
        XCTAssertThrowsError(try Self.driver(configuration)) { error in
            guard case let LethenError.usageError(message) = error else { return XCTFail("\(error)") }

            XCTAssertTrue(message.contains("-configuration"), message)
        }
    }

    func testRejectsSkipBuildWithoutIndexStorePaths() throws {
        let configuration = Self.configuration(["Debug", "Release"])
        configuration.skipBuild = true
        XCTAssertThrowsError(try Self.driver(configuration)) { error in
            guard case LethenError.usageError = error else { return XCTFail("\(error)") }
        }

        configuration.indexStorePath = [FilePath("/nonexistent/DataStore")]
        XCTAssertNoThrow(try Self.driver(configuration))
    }

    // MARK: - Private

    private static func configuration(_ configurations: [String]) -> Configuration {
        let configuration = Configuration()
        configuration.quiet = true
        configuration.schemes = ["ConfigurationsProject"]
        configuration.configurations = configurations
        return configuration
    }

    private static func driver(_ configuration: Configuration) throws -> XcodeProjectDriver {
        try XcodeProjectDriver(projectPath: ConfigurationsProjectPath, configuration: configuration, shell: shell, logger: logger)
    }

    /// A driver whose builds are recorded rather than run.
    private static func recordingDriver(_ configuration: Configuration, shell: RecordingShell) throws -> XcodeProjectDriver {
        let xcodebuild = Xcodebuild(shell: shell, logger: logger)
        var loaded: Set<FilePath> = []
        let project = try XcodeProject(path: ConfigurationsProjectPath, loadedProjectPaths: &loaded, xcodebuild: xcodebuild, shell: shell, logger: logger)
        try XcodeProjectDriver.validateConfigurations(configuration, project: project)
        return XcodeProjectDriver(logger: logger, configuration: configuration, xcodebuild: xcodebuild, project: project, schemes: ["ConfigurationsProject"])
    }
}

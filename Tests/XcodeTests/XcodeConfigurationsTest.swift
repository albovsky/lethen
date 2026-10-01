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
        XCTAssertEqual(configurations, ["Debug", "Release"])
        XCTAssertTrue(builds.allSatisfy { $0.contains("build-for-testing") })
        XCTAssertEqual(Set(shell.derivedDataPaths).count, 2, "\(shell.derivedDataPaths)")
    }

    func testCleanBuildRemovesEveryConfigurationsDerivedData() throws {
        let shell = RecordingShell()
        let configuration = Self.configuration(["Debug", "Release"])
        configuration.cleanBuild = true
        let driver = try Self.recordingDriver(configuration, shell: shell)

        // The first build records each configuration's DerivedData; the second clean build removes them all.
        try driver.build()
        let paths = Set(shell.derivedDataPaths)
        XCTAssertEqual(paths.count, 2)
        for path in paths {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        try driver.build()

        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "\(paths)")
        XCTAssertFalse(shell.executed.contains { $0.first == "rm" })
    }

    /// A configuration that does not build fails the scan; it is never retried as a plain build.
    func testFailingConfigurationBuildThrowsWithoutFallback() throws {
        let shell = RecordingShell(failingArgument: "Release")
        let driver = try Self.recordingDriver(Self.configuration(["Debug", "Release"]), shell: shell)

        XCTAssertThrowsError(try driver.build()) { error in
            guard case LethenError.shellCommandFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(shell.streamed.count, 2)
        XCTAssertTrue(shell.streamed.allSatisfy { $0.contains("-configuration") && $0.contains("build-for-testing") })
    }

    // MARK: - Scheme configurations

    /// ReleaseTests is ConfigurationsProject's scheme with its Test action switched to Release; it still runs with Debug.
    func testDefaultBuildOfAMismatchedSchemeCompilesItsTestConfiguration() throws {
        let configuration = Self.configuration([], scheme: "ReleaseTests")
        try Self.build(projectPath: ConfigurationsProjectPath, configuration: configuration)
        try Self.index(configuration: configuration)
        assertReferenced(.functionFree("calledOnlyInRelease()"))
        assertNotReferenced(.functionFree("calledOnlyInDebug()"))
    }

    func testReadsTheSchemesTestAndLaunchConfigurations() throws {
        let project = try Self.project()

        XCTAssertEqual(project.schemeConfigurations(named: "ConfigurationsProject"), .init(test: "Debug", launch: "Debug"))
        XCTAssertEqual(project.schemeConfigurations(named: "ReleaseTests"), .init(test: "Release", launch: "Debug"))
        XCTAssertNil(project.schemeConfigurations(named: "Undefined"))
    }

    /// Containers are searched in order, and a user's scheme counts when no shared one of that name exists.
    func testReadsUserSchemesFromTheFirstContainerThatDefinesThem() throws {
        let workspace = FilePath(NSTemporaryDirectory()).appending("lethen-\(UUID().uuidString)/App.xcworkspace")
        defer { try? FileManager.default.removeItem(atPath: workspace.removingLastComponent().string) }
        let userSchemes = workspace.appending("xcuserdata/someone.xcuserdatad/xcschemes")
        try FileManager.default.createDirectory(atPath: userSchemes.string, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: ConfigurationsProjectPath.appending("xcshareddata/xcschemes/ReleaseTests.xcscheme").string,
            toPath: userSchemes.appending("ConfigurationsProject.xcscheme").string
        )

        XCTAssertEqual(
            XcodeSchemeConfigurations.read(scheme: "ConfigurationsProject", in: [workspace, ConfigurationsProjectPath], user: "someone"),
            .init(test: "Release", launch: "Debug")
        )
        XCTAssertEqual(
            XcodeSchemeConfigurations.read(scheme: "ConfigurationsProject", in: [ConfigurationsProjectPath, workspace], user: "someone"),
            .init(test: "Debug", launch: "Debug")
        )
    }

    /// Another user's private scheme is invisible to xcodebuild, so it must not be read.
    func testIgnoresOtherUsersPrivateSchemes() throws {
        let project = FilePath(NSTemporaryDirectory()).appending("lethen-\(UUID().uuidString)/App.xcodeproj")
        defer { try? FileManager.default.removeItem(atPath: project.removingLastComponent().string) }
        let otherSchemes = project.appending("xcuserdata/another.xcuserdatad/xcschemes")
        try FileManager.default.createDirectory(atPath: otherSchemes.string, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            atPath: ConfigurationsProjectPath.appending("xcshareddata/xcschemes/ReleaseTests.xcscheme").string,
            toPath: otherSchemes.appending("App.xcscheme").string
        )

        XCTAssertNil(XcodeSchemeConfigurations.read(scheme: "App", in: [project], user: "someone"))
        XCTAssertEqual(XcodeSchemeConfigurations.read(scheme: "App", in: [project], user: "another"), .init(test: "Release", launch: "Debug"))
    }

    /// Scheme names are file names, not patterns: `App[Dev]` must not match `AppD`, and must match itself.
    func testReadsSchemeNamesWithPatternCharactersLiterally() throws {
        let project = FilePath(NSTemporaryDirectory()).appending("lethen-\(UUID().uuidString)/App.xcodeproj")
        defer { try? FileManager.default.removeItem(atPath: project.removingLastComponent().string) }
        let userSchemes = project.appending("xcuserdata/someone.xcuserdatad/xcschemes")
        try FileManager.default.createDirectory(atPath: userSchemes.string, withIntermediateDirectories: true)
        let source = ConfigurationsProjectPath.appending("xcshareddata/xcschemes")
        try FileManager.default.copyItem(
            atPath: source.appending("ReleaseTests.xcscheme").string,
            toPath: userSchemes.appending("AppD.xcscheme").string
        )

        XCTAssertNil(XcodeSchemeConfigurations.read(scheme: "App[Dev]", in: [project], user: "someone"))

        try FileManager.default.copyItem(
            atPath: source.appending("ConfigurationsProject.xcscheme").string,
            toPath: userSchemes.appending("App[Dev].xcscheme").string
        )

        XCTAssertEqual(XcodeSchemeConfigurations.read(scheme: "App[Dev]", in: [project], user: "someone"), .init(test: "Debug", launch: "Debug"))
        XCTAssertEqual(XcodeSchemeConfigurations.read(scheme: "AppD", in: [project], user: "someone"), .init(test: "Release", launch: "Debug"))
    }

    func testWarnsWhenTheTestAndLaunchConfigurationsDiffer() throws {
        let project = try Self.project()
        let warning = try XCTUnwrap(XcodeProjectDriver.configurationMismatchWarning(
            scheme: "ReleaseTests",
            schemeConfigurations: project.schemeConfigurations(named: "ReleaseTests"),
            configuration: Self.configuration([], scheme: "ReleaseTests")
        ))

        XCTAssertTrue(warning.contains("configuration Release but runs with Debug"), warning)
        XCTAssertTrue(warning.contains("--configurations Release Debug"), warning)
    }

    /// A configuration name with a space would split into several names when the printed flag is pasted.
    func testWarningQuotesConfigurationNamesThatAreNotOneShellWord() throws {
        let warning = try XCTUnwrap(XcodeProjectDriver.configurationMismatchWarning(
            scheme: "App",
            schemeConfigurations: .init(test: "App Store", launch: "Debug"),
            configuration: Self.configuration([], scheme: "App")
        ))

        XCTAssertTrue(warning.contains("--configurations 'App Store' Debug to scan both"), warning)
        XCTAssertEqual(XcodeProjectDriver.shellWord("Release-Beta_2.1"), "Release-Beta_2.1")
        XCTAssertEqual(XcodeProjectDriver.shellWord("Jo's $(Build)"), #"'Jo'\''s $(Build)'"#)
        XCTAssertEqual(XcodeProjectDriver.shellWord(""), "''")
    }

    func testDoesNotWarnWhenTheConfigurationIsChosenOrMatches() throws {
        let project = try Self.project()
        let mismatched = project.schemeConfigurations(named: "ReleaseTests")

        func warning(_ configurations: XcodeSchemeConfigurations?, _ configuration: Configuration) -> String? {
            XcodeProjectDriver.configurationMismatchWarning(scheme: "ReleaseTests", schemeConfigurations: configurations, configuration: configuration)
        }

        XCTAssertNil(warning(project.schemeConfigurations(named: "ConfigurationsProject"), Self.configuration([])))
        XCTAssertNil(warning(nil, Self.configuration([])))
        XCTAssertNil(warning(mismatched, Self.configuration(["Release"])))
        let buildArgumentConfiguration = Self.configuration([])
        buildArgumentConfiguration.buildArguments = ["-configuration", "Release"]
        XCTAssertNil(warning(mismatched, buildArgumentConfiguration))
    }

    func testBuildDescriptionNamesTheConfigurationThatIsBuilt() throws {
        let mismatched = try Self.project().schemeConfigurations(named: "ReleaseTests")

        func description(_ listed: String?, _ configurations: XcodeSchemeConfigurations?, _ arguments: [String] = []) -> String {
            XcodeProjectDriver.buildDescription(scheme: "ReleaseTests", listedConfiguration: listed, schemeConfigurations: configurations, buildArguments: arguments)
        }

        XCTAssertEqual(description(nil, mismatched), "Building ReleaseTests with configuration Release")
        XCTAssertEqual(description("Debug", mismatched), "Building ReleaseTests with configuration Debug")
        XCTAssertEqual(description(nil, mismatched, ["-configuration", "Debug"]), "Building ReleaseTests with configuration Debug")
        XCTAssertEqual(description(nil, nil), "Building ReleaseTests")
    }

    /// The warning only reports; the default build still leaves the configuration to the scheme.
    func testMismatchedSchemeStillBuildsWithoutAConfigurationArgument() throws {
        let shell = RecordingShell()
        let driver = try Self.recordingDriver(Self.configuration([], scheme: "ReleaseTests"), shell: shell)

        try driver.build()

        XCTAssertEqual(shell.streamed.count, 1)
        XCTAssertFalse(try XCTUnwrap(shell.streamed.first).contains("-configuration"))
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

    func testAcceptsSkipBuildWithAndWithoutIndexStorePaths() throws {
        let configuration = Self.configuration(["Debug", "Release"])
        configuration.skipBuild = true
        XCTAssertNoThrow(try Self.driver(configuration))

        configuration.indexStorePath = [FilePath("/nonexistent/DataStore")]
        XCTAssertNoThrow(try Self.driver(configuration))
    }

    // MARK: - Skip build

    /// `--skip-build --configurations` scans the index of each configuration's earlier build together, and refuses a
    /// configuration's index that predates an edit even when another configuration's index was rebuilt since.
    func testSkipBuildReadsEveryConfigurationsIndexAndRejectsAStaleOne() throws {
        let root = FilePath(NSTemporaryDirectory()).appending("lethen configurations \(UUID().uuidString)")
        let copy = root.appending("ConfigurationsProject")
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: ConfigurationsProjectPath.removingLastComponent().string, toPath: copy.string)
        let project = copy.appending("ConfigurationsProject.xcodeproj")
        // A build setting of its own keys this copy's DerivedData apart from the fixture's.
        let buildArguments = ["LETHEN_TEST_COPY=\(UUID().uuidString)"]
        let xcodebuild = Xcodebuild(shell: Self.shell, logger: Self.logger)
        defer {
            for name in ["Debug", "Release"] {
                try? xcodebuild.removeDerivedData(for: Self.project(at: project), allSchemes: ["ConfigurationsProject"], configuration: name, buildArguments: buildArguments)
            }
            try? FileManager.default.removeItem(atPath: root.string)
        }

        func configuration(_ configurations: [String], skipBuild: Bool) -> Configuration {
            let configuration = Self.configuration(configurations)
            configuration.buildArguments = buildArguments
            configuration.skipBuild = skipBuild
            return configuration
        }

        try Self.build(projectPath: project, configuration: configuration(["Debug", "Release"], skipBuild: false))
        Self.plan = nil

        let skipBuild = configuration(["Debug", "Release"], skipBuild: true)
        try project.chdir {
            let driver = try XcodeProjectDriver(projectPath: project, configuration: skipBuild, shell: Self.shell, logger: Self.logger)
            Self.plan = try driver.plan(logger: Self.logger.contextualized(with: "index"))
        }
        try Self.index(configuration: skipBuild)
        assertReferenced(.functionFree("calledOnlyInDebug()"))
        assertReferenced(.functionFree("calledOnlyInRelease()"))

        // Edited, then rebuilt in Release only: Debug's index still describes the old file.
        Thread.sleep(forTimeInterval: 1.1)
        let conditional = copy.appending("ConfigurationsProject/Conditional.swift")
        let text = try String(contentsOf: conditional.url, encoding: .utf8)
        try (text + "\n// edited after indexing\n").write(to: conditional.url, atomically: true, encoding: .utf8)
        try Self.build(projectPath: project, configuration: configuration(["Release"], skipBuild: false))

        let debugStore = try xcodebuild.indexStorePath(project: Self.project(at: project), schemes: ["ConfigurationsProject"], configuration: "Debug", buildArguments: buildArguments)
        XCTAssertThrowsError(try project.chdir {
            let driver = try XcodeProjectDriver(projectPath: project, configuration: skipBuild, shell: Self.shell, logger: Self.logger)
            _ = try driver.plan(logger: Self.logger.contextualized(with: "index"))
        }) { error in
            guard case let LethenError.staleIndexStore(path, staleFiles) = error else { return XCTFail("\(error)") }

            XCTAssertEqual(path, debugStore.string)
            XCTAssertEqual(staleFiles.map { FilePath($0).lastComponent?.string }, ["Conditional.swift"])
        }
    }

    /// Each listed configuration needs Lethen's own index for it; Xcode's DerivedData index, which holds one
    /// configuration, never stands in for a missing one.
    func testSkipBuildFailsWhenAConfigurationHasNoIndexOfItsOwn() throws {
        let root = FilePath(NSTemporaryDirectory()).appending("lethen configurations \(UUID().uuidString)")
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let project = try Self.project(shell: shell)
        let configuration = Self.configuration(["Debug", "Release"])
        configuration.skipBuild = true
        configuration.buildArguments = ["LETHEN_TEST_MISSING=\(UUID().uuidString)"]
        let debugDerivedData = try xcodebuild.derivedDataPath(for: project, schemes: ["ConfigurationsProject"], configuration: "Debug", buildArguments: configuration.buildArguments)
        defer {
            try? FileManager.default.removeItem(atPath: root.string)
            try? FileManager.default.removeItem(atPath: debugDerivedData.string)
        }

        // Xcode has indexed the project, which is what a plain --skip-build would read.
        let xcodeDerivedData = root.appending("DerivedData/ConfigurationsProject-xcode")
        try FileManager.default.createDirectory(atPath: xcodeDerivedData.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": ConfigurationsProjectPath.string], format: .xml, options: 0)
        try info.write(to: xcodeDerivedData.appending("info.plist").url)
        let locator = XcodeDerivedDataLocator(root: root.appending("DerivedData"))
        XCTAssertEqual(locator.indexStores(for: ConfigurationsProjectPath).count, 1)

        let driver = XcodeProjectDriver(logger: Self.logger, configuration: configuration, xcodebuild: xcodebuild, project: project, schemes: ["ConfigurationsProject"], derivedDataLocator: locator)

        func message() -> String? {
            do {
                _ = try driver.plan(logger: Self.logger.contextualized(with: "index"))
            } catch let LethenError.usageError(message) {
                return message
            } catch {
                XCTFail("\(error)")
            }
            return nil
        }

        XCTAssertTrue(try XCTUnwrap(message()).contains("no index from Lethen's build of configurations Debug Release."))

        try FileManager.default.createDirectory(atPath: debugDerivedData.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        XCTAssertTrue(try XCTUnwrap(message()).contains("no index from Lethen's build of configuration Release."))
    }

    // MARK: - Private

    private static func configuration(_ configurations: [String], scheme: String = "ConfigurationsProject") -> Configuration {
        let configuration = Configuration()
        configuration.quiet = true
        configuration.schemes = [scheme]
        configuration.configurations = configurations
        return configuration
    }

    private static func driver(_ configuration: Configuration) throws -> XcodeProjectDriver {
        try XcodeProjectDriver(projectPath: ConfigurationsProjectPath, configuration: configuration, shell: shell, logger: logger)
    }

    private static func project(at path: FilePath = ConfigurationsProjectPath, shell: Shell = RecordingShell()) throws -> XcodeProject {
        var loaded: Set<FilePath> = []
        return try XcodeProject(
            path: path,
            loadedProjectPaths: &loaded,
            xcodebuild: Xcodebuild(shell: shell, logger: logger),
            shell: shell,
            logger: logger
        )
    }

    /// A driver whose builds are recorded rather than run.
    private static func recordingDriver(_ configuration: Configuration, shell: RecordingShell) throws -> XcodeProjectDriver {
        let xcodebuild = Xcodebuild(shell: shell, logger: logger)
        let project = try project(shell: shell)
        try XcodeProjectDriver.validateConfigurations(configuration, project: project)
        return XcodeProjectDriver(logger: logger, configuration: configuration, xcodebuild: xcodebuild, project: project, schemes: Set(configuration.schemes))
    }
}

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
        // A leftover from an earlier build in each; the scan recreates the directories to record its own build.
        let leftovers = paths.map { FilePath($0).appending("Build/leftover").string }
        for leftover in leftovers {
            try FileManager.default.createDirectory(atPath: leftover, withIntermediateDirectories: true)
        }
        try driver.build()

        XCTAssertTrue(leftovers.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "\(leftovers)")
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

        XCTAssertTrue(try XCTUnwrap(message()).contains("no index from a completed Lethen build of configurations Debug Release."))

        // A store without the marker is what a failed or interrupted build leaves behind.
        try FileManager.default.createDirectory(atPath: debugDerivedData.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        XCTAssertTrue(try XCTUnwrap(message()).contains("no index from a completed Lethen build of configurations Debug Release."))

        // A project of the same name elsewhere shares the DerivedData directory, but its build does not count.
        let marker = debugDerivedData.appending(Xcodebuild.completedBuildMarker).string
        let ownMark = try XCTUnwrap(String(
            bytes: Xcodebuild.markerContents(project: project, schemes: ["ConfigurationsProject"], configuration: "Debug", buildArguments: configuration.buildArguments),
            encoding: .utf8
        ))
        let elsewhere = ownMark.replacingOccurrences(of: project.path.lexicallyNormalized().string, with: "/elsewhere/ConfigurationsProject.xcodeproj")
        XCTAssertNotEqual(elsewhere, ownMark)
        FileManager.default.createFile(atPath: marker, contents: Data(elsewhere.utf8))
        XCTAssertTrue(try XCTUnwrap(message()).contains("no index from a completed Lethen build of configurations Debug Release."))

        // A completed build, which starts by replacing the directory that recorded no build.
        try Self.markComplete(xcodebuild, project: project, schemes: ["ConfigurationsProject"], configuration: "Debug", buildArguments: configuration.buildArguments)
        try FileManager.default.createDirectory(atPath: debugDerivedData.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        XCTAssertTrue(try XCTUnwrap(message()).contains("no index from a completed Lethen build of configuration Release."))
    }

    /// Each configuration's DerivedData is marked complete only once every scheme has built into it, so a scan that
    /// stops after one scheme leaves no configuration marked, even one an earlier scan completed.
    func testOnlyBuildsOfEverySchemeMarkAConfigurationComplete() throws {
        let configuration = Self.configuration(["Debug", "Release"])
        configuration.schemes = ["ConfigurationsProject", "ReleaseTests"]
        configuration.buildArguments = ["LETHEN_TEST_MARKER=\(UUID().uuidString)"]
        let shell = RecordingShell(failingArgument: "ReleaseTests")
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let project = try Self.project(shell: shell)
        let derivedData = try ["Debug", "Release"].map {
            try xcodebuild.derivedDataPath(for: project, schemes: configuration.schemes, configuration: $0, buildArguments: configuration.buildArguments)
        }
        defer { derivedData.forEach { try? FileManager.default.removeItem(atPath: $0.string) } }
        for directory in derivedData {
            try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
        }
        for name in ["Debug", "Release"] {
            try Self.markComplete(xcodebuild, project: project, schemes: configuration.schemes, configuration: name, buildArguments: configuration.buildArguments)
        }

        func completed() throws -> [Bool] {
            try ["Debug", "Release"].map {
                try xcodebuild.hasCompletedBuild(project: project, schemes: configuration.schemes, configuration: $0, buildArguments: configuration.buildArguments)
            }
        }

        // ConfigurationsProject builds in both configurations, then ReleaseTests fails.
        XCTAssertEqual(try completed(), [true, true])
        let failing = try Self.recordingDriver(configuration, shell: shell)
        XCTAssertThrowsError(try failing.build())
        XCTAssertEqual(shell.streamed.count, 3)
        XCTAssertEqual(try completed(), [false, false])
        XCTAssertNoThrow(try DerivedDataLock(directories: derivedData, exclusive: true, wait: false), "A failed build must release its lock.")

        let succeeding = try Self.recordingDriver(configuration, shell: RecordingShell())
        try succeeding.build()
        XCTAssertEqual(try completed(), [true, true])
    }

    /// Scheme sets whose names join to the same string share a DerivedData directory, so the mark must tell them apart.
    func testCompletedBuildNamesTheExactSchemes() throws {
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let project = try Self.project(shell: shell)
        let buildArguments = ["LETHEN_TEST_SCHEMES=\(UUID().uuidString)"]
        let built = try xcodebuild.derivedDataPath(for: project, schemes: ["A", "BC"], configuration: "Debug", buildArguments: buildArguments)
        let other = try xcodebuild.derivedDataPath(for: project, schemes: ["AB", "C"], configuration: "Debug", buildArguments: buildArguments)
        XCTAssertEqual(built, other)
        defer { try? FileManager.default.removeItem(atPath: built.string) }
        try FileManager.default.createDirectory(atPath: built.string, withIntermediateDirectories: true)

        try Self.markComplete(xcodebuild, project: project, schemes: ["BC", "A"], configuration: "Debug", buildArguments: buildArguments)

        XCTAssertTrue(try xcodebuild.hasCompletedBuild(project: project, schemes: ["A", "BC"], configuration: "Debug", buildArguments: buildArguments))
        XCTAssertFalse(try xcodebuild.hasCompletedBuild(project: project, schemes: ["AB", "C"], configuration: "Debug", buildArguments: buildArguments))
    }

    /// A directory last built for another project of the same name or another scheme set that hashes alike, or by a
    /// Lethen that recorded nothing, is removed before building, since an incremental build would keep its units.
    func testBuildRemovesADirectoryLastBuiltForAnotherIdentity() throws {
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let project = try Self.project(shell: shell)
        let buildArguments = ["LETHEN_TEST_IDENTITY=\(UUID().uuidString)"]
        let directory = try xcodebuild.derivedDataPath(for: project, schemes: ["A", "BC"], configuration: "Debug", buildArguments: buildArguments)
        let leftover = directory.appending("Index.noindex/DataStore/v5/units/leftover")
        defer { try? FileManager.default.removeItem(atPath: directory.string) }

        func plant() throws {
            try FileManager.default.createDirectory(atPath: leftover.string, withIntermediateDirectories: true)
        }

        func begin(_ schemes: [String]) throws {
            try xcodebuild.beginBuild(project: project, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        }

        try plant()
        try begin(["A", "BC"])
        XCTAssertFalse(leftover.exists, "A directory that records no build is not trusted.")

        try plant()
        try begin(["BC", "A"])
        XCTAssertTrue(leftover.exists, "The same project and schemes build on their previous build.")

        try begin(["AB", "C"])
        XCTAssertFalse(leftover.exists, "Another scheme set must not inherit the units.")
    }

    /// Building takes the configuration's DerivedData exclusively and reading it without a build takes it shared, so
    /// a scan never reads or marks a store that another scan is building.
    func testDerivedDataLocksExcludeBuildsFromReadsAndOtherBuilds() throws {
        let directory = FilePath(NSTemporaryDirectory()).appending("lethen-lock-\(UUID().uuidString)/DerivedData-test")
        defer { try? FileManager.default.removeItem(atPath: directory.removingLastComponent().string) }

        func lock(exclusive: Bool) throws -> DerivedDataLock {
            try DerivedDataLock(directories: [directory], exclusive: exclusive, wait: false)
        }

        let building = try lock(exclusive: true)
        XCTAssertThrowsError(try lock(exclusive: false))
        XCTAssertThrowsError(try lock(exclusive: true))
        building.release()

        let reading = try lock(exclusive: false)
        XCTAssertNoThrow(try lock(exclusive: false))
        XCTAssertThrowsError(try lock(exclusive: true))
        reading.release()
        XCTAssertNoThrow(try lock(exclusive: true))
    }

    /// The driver keeps the DerivedData it built into, or read without a build, locked until it is released, since
    /// the index pipeline reads the stores' records after `plan()` returns.
    func testDriverHoldsTheDerivedDataLockUntilItIsReleased() throws {
        let configuration = Self.configuration(["Debug", "Release"])
        configuration.buildArguments = ["LETHEN_TEST_DRIVER_LOCK=\(UUID().uuidString)"]
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let project = try Self.project(shell: shell)
        let directories = try ["Debug", "Release"].map {
            try xcodebuild.derivedDataPath(for: project, schemes: configuration.schemes, configuration: $0, buildArguments: configuration.buildArguments)
        }
        defer {
            for directory in directories {
                try? FileManager.default.removeItem(atPath: directory.string)
                try? FileManager.default.removeItem(atPath: directory.string + ".lock")
            }
        }

        func locked() -> Bool {
            (try? DerivedDataLock(directories: directories, exclusive: true, wait: false)) == nil
        }

        var builder: XcodeProjectDriver? = try Self.recordingDriver(configuration, shell: shell)
        try builder?.build()
        XCTAssertTrue(locked())
        builder = nil
        XCTAssertFalse(locked())

        for directory in directories {
            try FileManager.default.createDirectory(atPath: directory.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        }
        configuration.skipBuild = true
        var reader: XcodeProjectDriver? = try Self.recordingDriver(configuration, shell: shell)
        _ = try? reader?.plan(logger: Self.logger.contextualized(with: "index"))
        XCTAssertTrue(locked())
        reader = nil
        XCTAssertFalse(locked())

        // A plain --skip-build may pick Lethen's own store too, so it reads it under the same lock.
        let plain = Self.configuration([])
        plain.buildArguments = configuration.buildArguments
        plain.skipBuild = true
        let ownDirectory = try xcodebuild.derivedDataPath(for: project, schemes: plain.schemes, buildArguments: plain.buildArguments)
        defer {
            try? FileManager.default.removeItem(atPath: ownDirectory.string)
            try? FileManager.default.removeItem(atPath: ownDirectory.string + ".lock")
        }
        try FileManager.default.createDirectory(atPath: ownDirectory.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        var plainReader: XcodeProjectDriver? = try Self.recordingDriver(plain, shell: shell)
        _ = try? plainReader?.plan(logger: Self.logger.contextualized(with: "index"))
        XCTAssertThrowsError(try DerivedDataLock(directories: [ownDirectory], exclusive: true, wait: false))
        plainReader = nil
        XCTAssertNoThrow(try DerivedDataLock(directories: [ownDirectory], exclusive: true, wait: false))
    }

    /// Removing a directory can fail part way, so its completion mark is removed before any of its contents: by a
    /// clean build for every configuration, and before a directory built for another identity is replaced.
    func testCompletionMarksGoBeforeAnyRemoval() throws {
        let configuration = Self.configuration(["Debug", "Release"])
        configuration.buildArguments = ["LETHEN_TEST_ORDER=\(UUID().uuidString)"]
        configuration.cleanBuild = true
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let project = try Self.project(shell: shell)
        let directories = try ["Debug", "Release"].map {
            try xcodebuild.derivedDataPath(for: project, schemes: configuration.schemes, configuration: $0, buildArguments: configuration.buildArguments)
        }
        defer {
            for directory in directories {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appending("Index.noindex").string)
                try? FileManager.default.removeItem(atPath: directory.string)
                try? FileManager.default.removeItem(atPath: directory.string + ".lock")
            }
        }

        func completed() throws -> [Bool] {
            try ["Debug", "Release"].map {
                try xcodebuild.hasCompletedBuild(project: project, schemes: configuration.schemes, configuration: $0, buildArguments: configuration.buildArguments)
            }
        }

        // Release's index cannot be removed, so the clean build fails part way through that directory.
        for name in ["Debug", "Release"] {
            try Self.markComplete(xcodebuild, project: project, schemes: configuration.schemes, configuration: name, buildArguments: configuration.buildArguments)
        }
        let stuck = directories[1].appending("Index.noindex")
        try FileManager.default.createDirectory(atPath: stuck.appending("DataStore/v5/units").string, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuck.string)
        XCTAssertEqual(try completed(), [true, true])

        XCTAssertThrowsError(try Self.recordingDriver(configuration, shell: shell).build())
        XCTAssertEqual(try completed(), [false, false])
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

    private static func markComplete(_ xcodebuild: Xcodebuild, project: XcodeProject, schemes: [String], configuration: String, buildArguments: [String]) throws {
        try xcodebuild.beginBuild(project: project, schemes: schemes, configuration: configuration, buildArguments: buildArguments)
        try xcodebuild.completeBuild(project: project, schemes: schemes, configuration: configuration, buildArguments: buildArguments)
    }

    /// A driver whose builds are recorded rather than run.
    private static func recordingDriver(_ configuration: Configuration, shell: RecordingShell) throws -> XcodeProjectDriver {
        let xcodebuild = Xcodebuild(shell: shell, logger: logger)
        let project = try project(shell: shell)
        try XcodeProjectDriver.validateConfigurations(configuration, project: project)
        return XcodeProjectDriver(logger: logger, configuration: configuration, xcodebuild: xcodebuild, project: project, schemes: Set(configuration.schemes))
    }
}

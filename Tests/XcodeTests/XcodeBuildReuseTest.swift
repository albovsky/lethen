import Configuration
import Foundation
import Logger
@testable import ProjectDrivers
import Shared
import SystemPackage
@testable import TestShared
@testable import XcodeSupport
import XCTest

/// A scan reuses Lethen's own completed build when nothing it compiled changed, so a rescan runs no xcodebuild; it
/// builds when anything changed, and `plan()` builds when a unit predates its file after all. Results are the same
/// either way.
final class XcodeBuildReuseTest: XcodeSourceGraphTestCase {
    private var root: FilePath!
    private var project: FilePath!
    private var buildArguments: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FilePath(NSTemporaryDirectory()).appending("lethen reuse \(UUID().uuidString)")
        let copy = root.appending("ConfigurationsProject")
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: ConfigurationsProjectPath.removingLastComponent().string, toPath: copy.string)
        project = copy.appending("ConfigurationsProject.xcodeproj")
        // A build setting of its own keys this copy's DerivedData apart from every other test's.
        buildArguments = ["LETHEN_TEST_REUSE=\(UUID().uuidString)"]
    }

    override func tearDownWithError() throws {
        let xcodebuild = Xcodebuild(shell: Self.shell, logger: Self.logger)
        if let project, let loaded = try? Self.load(project, shell: Self.shell) {
            for name in [nil, "Debug", "Release"] {
                try? xcodebuild.removeDerivedData(for: loaded, allSchemes: ["ConfigurationsProject"], configuration: name, buildArguments: buildArguments)
            }
        }
        if let root {
            try? FileManager.default.removeItem(atPath: root.string)
        }
        try super.tearDownWithError()
    }

    // MARK: - Reuse

    func testRescanOfAnUnchangedProjectRunsNoBuild() throws {
        let shell = ForwardingRecordingShell(logger: Self.logger)
        let first = try scan(shell: shell)
        XCTAssertEqual(first.builds, 1)
        assertReferenced(.functionFree("calledOnlyInDebug()"))
        assertNotReferenced(.functionFree("calledOnlyInRelease()"))
        let firstFiles = try Set(XCTUnwrap(Self.plan).sourceFiles.keys.map(\.path))

        let second = try scan(shell: shell)

        XCTAssertEqual(second.builds, 0, "\(shell.streamed)")
        XCTAssertEqual(second.buildsInPlan, 0)
        XCTAssertEqual(try Set(XCTUnwrap(Self.plan).sourceFiles.keys.map(\.path)), firstFiles)
        assertReferenced(.functionFree("calledOnlyInDebug()"))
        assertNotReferenced(.functionFree("calledOnlyInRelease()"))
    }

    func testEditedSourceBuildsAndIndexesTheEdit() throws {
        let shell = ForwardingRecordingShell(logger: Self.logger)
        _ = try scan(shell: shell)

        Thread.sleep(forTimeInterval: 1.1)
        try addCalledFunction("addedAfterTheFirstScan")
        let second = try scan(shell: shell)

        XCTAssertEqual(second.builds, 1, "\(shell.streamed)")
        assertReferenced(.functionFree("addedAfterTheFirstScan()"))
        assertReferenced(.functionFree("calledOnlyInDebug()"))
    }

    func testStructuralChangeBuilds() throws {
        let shell = ForwardingRecordingShell(logger: Self.logger)
        _ = try scan(shell: shell)

        Thread.sleep(forTimeInterval: 1.1)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: project.appending("project.pbxproj").string)
        let second = try scan(shell: shell)

        XCTAssertEqual(second.builds, 1, "\(shell.streamed)")
        assertReferenced(.functionFree("calledOnlyInDebug()"))
    }

    func testFileAddedToTheProjectDirectoryBuilds() throws {
        let shell = ForwardingRecordingShell(logger: Self.logger)
        _ = try scan(shell: shell)

        Thread.sleep(forTimeInterval: 1.1)
        try "func unlisted() {}\n".write(to: project.removingLastComponent().appending("ConfigurationsProject/Unlisted.swift").url, atomically: true, encoding: .utf8)
        let second = try scan(shell: shell)

        XCTAssertEqual(second.builds, 1, "\(shell.streamed)")
    }

    /// Dates that the walk cannot tell apart from an unchanged project still end in a build, because the collector
    /// compares each indexed file with its own unit.
    func testPlanBuildsWhenAUnitPredatesItsFileThatTheWalkMissed() throws {
        let shell = ForwardingRecordingShell(logger: Self.logger)
        _ = try scan(shell: shell)

        Thread.sleep(forTimeInterval: 1.1)
        try addCalledFunction("addedBehindTheWalk")
        // The build now appears to have started and completed after the edit.
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let loaded = try Self.load(project, shell: shell)
        let directory = try xcodebuild.derivedDataPath(for: loaded, schemes: ["ConfigurationsProject"], buildArguments: buildArguments)
        let now = Date()
        for marker in [Xcodebuild.startedBuildMarker, Xcodebuild.completedBuildMarker] {
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: directory.appending(marker).string)
        }

        let second = try scan(shell: shell)

        XCTAssertEqual(second.builds, 0, "\(shell.streamed)")
        XCTAssertEqual(second.buildsInPlan, 1, "\(shell.streamed)")
        assertReferenced(.functionFree("addedBehindTheWalk()"))
    }

    // MARK: - Never reused

    func testCleanBuildNeverReuses() throws {
        let shell = ForwardingRecordingShell(logger: Self.logger)
        _ = try scan(shell: shell)

        let second = try scan(shell: shell) { $0.cleanBuild = true }

        XCTAssertEqual(second.builds, 1, "\(shell.streamed)")
    }

    func testSkipBuildStillRefusesAStaleIndexWithoutBuilding() throws {
        let shell = ForwardingRecordingShell(logger: Self.logger)
        _ = try scan(shell: shell)
        let builds = shell.streamed.count

        Thread.sleep(forTimeInterval: 1.1)
        try editConditional { $0 + "\n// edited after the build\n" }

        XCTAssertThrowsError(try scan(shell: shell) { $0.skipBuild = true }) { error in
            guard case LethenError.staleIndexStore = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(shell.streamed.count, builds)
    }

    func testExplicitIndexStorePathNeverReuses() throws {
        let shell = ForwardingRecordingShell(logger: Self.logger)
        _ = try scan(shell: shell)
        let loaded = try Self.load(project, shell: shell)
        let store = try Xcodebuild(shell: shell, logger: Self.logger)
            .indexStorePath(project: loaded, schemes: ["ConfigurationsProject"], buildArguments: buildArguments)

        let second = try scan(shell: shell) { $0.indexStorePath = [store] }

        XCTAssertEqual(second.builds, 1, "\(shell.streamed)")
    }

    // MARK: - Configurations

    /// Only the configurations whose builds cannot be reused are built.
    func testOnlyAConfigurationWithoutACompletedBuildIsBuilt() throws {
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let loaded = try Self.load(project, shell: shell)
        let schemes = ["ConfigurationsProject"]
        let directory = try xcodebuild.derivedDataPath(for: loaded, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        defer {
            for name in ["Debug", "Release"] {
                if let path = try? xcodebuild.derivedDataPath(for: loaded, schemes: schemes, configuration: name, buildArguments: buildArguments) {
                    try? FileManager.default.removeItem(atPath: path.string)
                    try? FileManager.default.removeItem(atPath: path.string + ".lock")
                }
            }
        }

        try xcodebuild.beginBuild(project: loaded, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        try xcodebuild.completeBuild(project: loaded, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        try FileManager.default.createDirectory(atPath: directory.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        // The project's files predate the planted build.
        let old = Date(timeIntervalSinceNow: -3600)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.string))
        for case let relative as String in enumerator {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appending(relative).string)
        }

        let configuration = Self.configuration(["Debug", "Release"], buildArguments: buildArguments)
        let driver = XcodeProjectDriver(logger: Self.logger, configuration: configuration, xcodebuild: xcodebuild, project: loaded, schemes: Set(schemes))
        try driver.build()

        let configurations = try shell.streamed.map { command in
            let index = try XCTUnwrap(command.firstIndex(of: "-configuration"))
            return command[index + 1]
        }
        XCTAssertEqual(configurations, ["Release"], "\(shell.streamed)")
    }

    /// A workspace's member project can live outside the workspace's directory; a file added there changes what the
    /// build compiles, so the completed build is not reused.
    func testFileAddedToAMemberProjectOutsideTheWorkspaceDirectoryBuilds() throws {
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let workspacePath = root.appending("Workspace/App.xcworkspace")
        try FileManager.default.createDirectory(atPath: workspacePath.string, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:../ConfigurationsProject/ConfigurationsProject.xcodeproj"></FileRef>
        </Workspace>
        """.write(to: workspacePath.appending("contents.xcworkspacedata").url, atomically: true, encoding: .utf8)
        let configuration = Self.configuration(["Debug"], buildArguments: buildArguments)
        let workspace = try XcodeWorkspace(path: workspacePath, xcodebuild: xcodebuild, configuration: configuration, logger: Self.logger, shell: shell)
        let schemes = ["ConfigurationsProject"]
        let directory = try xcodebuild.derivedDataPath(for: workspace, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        defer {
            try? FileManager.default.removeItem(atPath: directory.string)
            try? FileManager.default.removeItem(atPath: directory.string + ".lock")
        }

        try xcodebuild.beginBuild(project: workspace, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        try xcodebuild.completeBuild(project: workspace, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        try FileManager.default.createDirectory(atPath: directory.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        // Everything predates the planted build, then a new file appears in the member project.
        let old = Date(timeIntervalSinceNow: -3600)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.string))
        for case let relative as String in enumerator {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appending(relative).string)
        }
        let memberDirectory = project.removingLastComponent()
        try "func unlisted() {}\n".write(to: memberDirectory.appending("ConfigurationsProject/Unlisted.swift").url, atomically: true, encoding: .utf8)

        let driver = XcodeProjectDriver(logger: Self.logger, configuration: configuration, xcodebuild: xcodebuild, project: workspace, schemes: Set(schemes))
        try driver.build()

        XCTAssertEqual(shell.streamed.count, 1, "\(shell.streamed)")
    }

    func testFileAddedToAProjectReferencedFromOutsideTheScannedDirectoryBuilds() throws {
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        // A second project beside the scanned one's directory, which the scanned project references as a file.
        let referenced = root.appending("Referenced")
        try FileManager.default.copyItem(atPath: ConfigurationsProjectPath.removingLastComponent().string, toPath: referenced.string)
        let pbxproj = project.appending("project.pbxproj")
        var text = try String(contentsOf: pbxproj.url, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "/* Begin PBXFileReference section */\n",
            with: "/* Begin PBXFileReference section */\n\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* Referenced.xcodeproj */ = {isa = PBXFileReference; lastKnownFileType = \"wrapper.pb-project\"; name = Referenced.xcodeproj; path = ../Referenced/ConfigurationsProject.xcodeproj; sourceTree = \"<group>\"; };\n"
        )
        text = text.replacingOccurrences(
            of: "\t\t\t\t3C57B168ABF45A4AEDE2A1AB /* Products */,\n\t\t\t);\n\t\t\tsourceTree",
            with: "\t\t\t\t3C57B168ABF45A4AEDE2A1AB /* Products */,\n\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* Referenced.xcodeproj */,\n\t\t\t);\n\t\t\tsourceTree"
        )
        try text.write(to: pbxproj.url, atomically: true, encoding: .utf8)
        let configuration = Self.configuration(["Debug"], buildArguments: buildArguments)
        let scanned = try Self.load(project, shell: shell)
        XCTAssertTrue(
            scanned.projectSourceRoots.contains { $0.lexicallyNormalized() == referenced.lexicallyNormalized() },
            "\(scanned.projectSourceRoots)"
        )
        let schemes = ["ConfigurationsProject"]
        let directory = try xcodebuild.derivedDataPath(for: scanned, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        defer {
            try? FileManager.default.removeItem(atPath: directory.string)
            try? FileManager.default.removeItem(atPath: directory.string + ".lock")
        }

        try xcodebuild.beginBuild(project: scanned, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        try xcodebuild.completeBuild(project: scanned, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        try FileManager.default.createDirectory(atPath: directory.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        // Everything predates the planted build, then a new file appears in the referenced project.
        let old = Date(timeIntervalSinceNow: -3600)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.string))
        for case let relative as String in enumerator {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appending(relative).string)
        }
        try "func unlisted() {}\n".write(to: referenced.appending("ConfigurationsProject/Unlisted.swift").url, atomically: true, encoding: .utf8)

        let driver = XcodeProjectDriver(logger: Self.logger, configuration: configuration, xcodebuild: xcodebuild, project: scanned, schemes: Set(schemes))
        try driver.build()

        XCTAssertEqual(shell.streamed.count, 1, "\(shell.streamed)")
    }

    /// A build setting file the project declares can live outside its directory; editing it changes how the build
    /// compiles, such as its Swift compilation conditions, so the completed build is not reused.
    func testEditedXcconfigOutsideTheScannedDirectoryBuilds() throws {
        let xcconfig = try declareExternalXcconfig()

        try assertBuilds(afterPlantedBuildDoing: {
            try "SWIFT_ACTIVE_COMPILATION_CONDITIONS = B\n".write(to: xcconfig.url, atomically: false, encoding: .utf8)
        })
    }

    /// The walk of the project's directory does not follow symlinks, and an edit to a file in a symlink's target
    /// changes neither the link nor a directory, so a declared file behind a symlinked directory is compared itself.
    func testEditedXcconfigBehindASymlinkedDirectoryBuilds() throws {
        let xcconfig = try externalFile("Extra.xcconfig", contents: "SWIFT_ACTIVE_COMPILATION_CONDITIONS = A\n")
        try FileManager.default.createSymbolicLink(
            atPath: root.appending("ConfigurationsProject/Linked").string,
            withDestinationPath: xcconfig.removingLastComponent().string
        )
        try editProject { text in
            text.replacingOccurrences(
                of: "/* Begin PBXFileReference section */\n",
                with: "/* Begin PBXFileReference section */\n\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* Extra.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = Extra.xcconfig; path = Linked/Extra.xcconfig; sourceTree = \"<group>\"; };\n"
            ).replacingOccurrences(
                of: "\t\t\t\t3C57B168ABF45A4AEDE2A1AB /* Products */,\n\t\t\t);\n\t\t\tsourceTree",
                with: "\t\t\t\t3C57B168ABF45A4AEDE2A1AB /* Products */,\n\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* Extra.xcconfig */,\n\t\t\t);\n\t\t\tsourceTree"
            )
        }

        try assertBuilds(afterPlantedBuildDoing: {
            try "SWIFT_ACTIVE_COMPILATION_CONDITIONS = B\n".write(to: xcconfig.url, atomically: false, encoding: .utf8)
        })
    }

    /// A declared file that no longer exists is a change, not a file to forget.
    func testDeletedXcconfigOutsideTheScannedDirectoryBuilds() throws {
        let xcconfig = try declareExternalXcconfig()

        try assertBuilds(afterPlantedBuildDoing: {
            try FileManager.default.removeItem(atPath: xcconfig.string)
        })
    }

    /// A local package outside the project's directory is compiled with the project; a file added to it changes what
    /// the build compiles, so the completed build is not reused.
    func testFileAddedToALocalPackageOutsideTheScannedDirectoryBuilds() throws {
        let package = try declareExternalLocalPackage()

        try assertBuilds(afterPlantedBuildDoing: {
            try "public func added() {}\n".write(to: package.appending("Sources/Library/Added.swift").url, atomically: true, encoding: .utf8)
        })
    }

    func testDeletedLocalPackageOutsideTheScannedDirectoryBuilds() throws {
        let package = try declareExternalLocalPackage()

        try assertBuilds(afterPlantedBuildDoing: {
            try FileManager.default.removeItem(atPath: package.string)
        })
    }

    // MARK: - Run Script inputs

    /// A Run Script phase's input paths say what its script reads, so an edit to one outside the project's directory
    /// changes the build even though nothing else names the file.
    func testEditedRunScriptInputOutsideTheScannedDirectoryBuilds() throws {
        let input = try externalFile("Input.txt")
        try addScriptPhase(inputPaths: ["$(SRCROOT)/../External/Input.txt"])

        try assertBuilds(afterPlantedBuildDoing: {
            try "changed\n".write(to: input.url, atomically: false, encoding: .utf8)
        })
    }

    func testEditedFileListedInARunScriptInputFileListBuilds() throws {
        let input = try externalFile("Listed.txt")
        _ = try externalFile("Inputs.xcfilelist", contents: "${PROJECT_DIR}/../External/Listed.txt\n")
        try addScriptPhase(inputFileListPaths: ["$(SRCROOT)/../External/Inputs.xcfilelist"])

        try assertBuilds(afterPlantedBuildDoing: {
            try "changed\n".write(to: input.url, atomically: false, encoding: .utf8)
        })
    }

    /// An input that names a build setting Lethen cannot resolve could be any file, so nothing is reused.
    func testRunScriptInputWithAnUnresolvableVariableNeverReuses() throws {
        try addScriptPhase(inputPaths: ["$(DERIVED_FILE_DIR)/generated.txt"])

        try assertBuilds(afterPlantedBuildDoing: {})
    }

    /// A phase set to run on every build can write anything, and no file time says it did not.
    func testAlwaysOutOfDateRunScriptNeverReuses() throws {
        try addScriptPhase(alwaysOutOfDate: true)

        try assertBuilds(afterPlantedBuildDoing: {})
    }

    // MARK: - Declared paths

    /// A local package declared at a path inside the project's directory that is a symbolic link to a directory
    /// outside it is compiled with the project; the walk of the project's directory does not enter the link, so the
    /// package is walked as its target.
    func testFileAddedToALocalPackageBehindASymlinkedDirectoryBuilds() throws {
        let package = try declareExternalLocalPackage(relativePath: "Linked")
        try FileManager.default.createSymbolicLink(atPath: root.appending("ConfigurationsProject/Linked").string, withDestinationPath: package.string)

        try assertBuilds(afterPlantedBuildDoing: {
            try "public func added() {}\n".write(to: package.appending("Sources/Library/Added.swift").url, atomically: true, encoding: .utf8)
        })
    }

    func testRunScriptInputDirectoryBehindASymlinkedDirectoryBuilds() throws {
        let external = root.appending("External/Inputs")
        try FileManager.default.createDirectory(atPath: external.string, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appending("ConfigurationsProject/Linked").string, withDestinationPath: external.string)
        try addScriptPhase(inputPaths: ["$(SRCROOT)/Linked"])

        try assertBuilds(afterPlantedBuildDoing: {
            try "new\n".write(to: external.appending("Added.txt").url, atomically: true, encoding: .utf8)
        })
    }

    /// A member project that was deleted after the build cannot be loaded, but the workspace still lists it.
    func testDeletedMemberProjectOutsideTheWorkspaceDirectoryBuilds() throws {
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let workspacePath = root.appending("Workspace/App.xcworkspace")
        try FileManager.default.createDirectory(atPath: workspacePath.string, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:../ConfigurationsProject/ConfigurationsProject.xcodeproj"></FileRef>
        </Workspace>
        """.write(to: workspacePath.appending("contents.xcworkspacedata").url, atomically: true, encoding: .utf8)
        let configuration = Self.configuration(["Debug"], buildArguments: buildArguments)
        let planted = try XcodeWorkspace(path: workspacePath, xcodebuild: xcodebuild, configuration: configuration, logger: Self.logger, shell: shell)
        let schemes = ["ConfigurationsProject"]
        let directory = try xcodebuild.derivedDataPath(for: planted, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        defer {
            try? FileManager.default.removeItem(atPath: directory.string)
            try? FileManager.default.removeItem(atPath: directory.string + ".lock")
        }

        try xcodebuild.beginBuild(project: planted, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        try xcodebuild.completeBuild(project: planted, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        try FileManager.default.createDirectory(atPath: directory.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -3600)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.string))
        for case let relative as String in enumerator {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appending(relative).string)
        }
        try FileManager.default.removeItem(atPath: project.removingLastComponent().string)

        let workspace = try XcodeWorkspace(path: workspacePath, xcodebuild: xcodebuild, configuration: configuration, logger: Self.logger, shell: shell)
        let driver = XcodeProjectDriver(logger: Self.logger, configuration: configuration, xcodebuild: xcodebuild, project: workspace, schemes: Set(schemes))
        try driver.build()

        XCTAssertEqual(shell.streamed.count, 1, "\(shell.streamed)")
    }

    // MARK: - Private

    /// Declares `External/Extra.xcconfig`, outside the project's directory, as a file reference of the copy.
    private func declareExternalXcconfig() throws -> FilePath {
        let xcconfig = try externalFile("Extra.xcconfig", contents: "SWIFT_ACTIVE_COMPILATION_CONDITIONS = A\n")
        try editProject { text in
            text.replacingOccurrences(
                of: "/* Begin PBXFileReference section */\n",
                with: "/* Begin PBXFileReference section */\n\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* Extra.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = Extra.xcconfig; path = ../External/Extra.xcconfig; sourceTree = \"<group>\"; };\n"
            ).replacingOccurrences(
                of: "\t\t\t\t3C57B168ABF45A4AEDE2A1AB /* Products */,\n\t\t\t);\n\t\t\tsourceTree",
                with: "\t\t\t\t3C57B168ABF45A4AEDE2A1AB /* Products */,\n\t\t\t\tAAAAAAAAAAAAAAAAAAAAAAAA /* Extra.xcconfig */,\n\t\t\t);\n\t\t\tsourceTree"
            )
        }
        return xcconfig
    }

    /// Declares `ExternalPackage`, outside the project's directory, as a local Swift package of the copy at `relativePath`.
    private func declareExternalLocalPackage(relativePath: String = "../ExternalPackage") throws -> FilePath {
        let package = root.appending("ExternalPackage")
        try FileManager.default.createDirectory(atPath: package.appending("Sources/Library").string, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"ExternalPackage\", targets: [.target(name: \"Library\")])\n"
            .write(to: package.appending("Package.swift").url, atomically: true, encoding: .utf8)
        try "public func library() {}\n".write(to: package.appending("Sources/Library/Library.swift").url, atomically: true, encoding: .utf8)
        try editProject { text in
            text.replacingOccurrences(of: "\t\t\tmainGroup = ", with: "\t\t\tpackageReferences = (\n\t\t\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* XCLocalSwiftPackageReference \"\(relativePath)\" */,\n\t\t\t);\n\t\t\tmainGroup = ")
                .replacingOccurrences(
                    of: "/* End PBXProject section */\n",
                    with: "/* End PBXProject section */\n\n/* Begin XCLocalSwiftPackageReference section */\n\t\tBBBBBBBBBBBBBBBBBBBBBBBB /* XCLocalSwiftPackageReference \"\(relativePath)\" */ = {\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = \(relativePath);\n\t\t};\n/* End XCLocalSwiftPackageReference section */\n"
                )
        }
        return package
    }

    /// A file in `External`, a directory beside the copy that the project does not reference as a folder.
    private func externalFile(_ name: String, contents: String = "input\n") throws -> FilePath {
        let external = root.appending("External")
        try FileManager.default.createDirectory(atPath: external.string, withIntermediateDirectories: true)
        let file = external.appending(name)
        try contents.write(to: file.url, atomically: true, encoding: .utf8)
        return file
    }

    /// Adds a Run Script phase with these inputs to the copy's first target.
    private func addScriptPhase(inputPaths: [String] = [], inputFileListPaths: [String] = [], alwaysOutOfDate: Bool = false) throws {
        func list(_ paths: [String]) -> String {
            paths.map { "\t\t\t\t\"\($0)\",\n" }.joined()
        }
        try editProject { original in
            var text = original
            if let first = text.range(of: "\t\t\tbuildPhases = (\n") {
                text.insert(contentsOf: "\t\t\t\tCCCCCCCCCCCCCCCCCCCCCCCC /* Script */,\n", at: first.upperBound)
            }
            return text
                .replacingOccurrences(
                    of: "/* Begin PBXSourcesBuildPhase section */\n",
                    with: """
                    /* Begin PBXShellScriptBuildPhase section */
                    \t\tCCCCCCCCCCCCCCCCCCCCCCCC /* Script */ = {
                    \t\t\tisa = PBXShellScriptBuildPhase;
                    \t\t\talwaysOutOfDate = \(alwaysOutOfDate ? 1 : 0);
                    \t\t\tbuildActionMask = 2147483647;
                    \t\t\tfiles = (
                    \t\t\t);
                    \t\t\tinputFileListPaths = (
                    \(list(inputFileListPaths))\t\t\t);
                    \t\t\tinputPaths = (
                    \(list(inputPaths))\t\t\t);
                    \t\t\toutputFileListPaths = (
                    \t\t\t);
                    \t\t\toutputPaths = (
                    \t\t\t);
                    \t\t\trunOnlyForDeploymentPostprocessing = 0;
                    \t\t\tshellPath = /bin/sh;
                    \t\t\tshellScript = "true";
                    \t\t};
                    /* End PBXShellScriptBuildPhase section */

                    /* Begin PBXSourcesBuildPhase section */

                    """
                )
        }
    }

    private func editProject(_ edit: (String) -> String) throws {
        let pbxproj = project.appending("project.pbxproj")
        let text = try String(contentsOf: pbxproj.url, encoding: .utf8)
        let edited = edit(text)
        XCTAssertNotEqual(edited, text)
        try edited.write(to: pbxproj.url, atomically: true, encoding: .utf8)
    }

    /// Plants a completed build of the copy, ages every file, runs `change`, and expects `build()` to run one build.
    private func assertBuilds(afterPlantedBuildDoing change: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws {
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let configuration = Self.configuration(["Debug"], buildArguments: buildArguments)
        let scanned = try Self.load(project, shell: shell)
        let schemes = ["ConfigurationsProject"]
        let directory = try xcodebuild.derivedDataPath(for: scanned, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        defer {
            try? FileManager.default.removeItem(atPath: directory.string)
            try? FileManager.default.removeItem(atPath: directory.string + ".lock")
        }

        try xcodebuild.beginBuild(project: scanned, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        try xcodebuild.completeBuild(project: scanned, schemes: schemes, configuration: "Debug", buildArguments: buildArguments)
        try FileManager.default.createDirectory(atPath: directory.appending("Index.noindex/DataStore/v5/units").string, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -3600)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.string), file: file, line: line)
        for case let relative as String in enumerator {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appending(relative).string)
        }
        try change()

        let driver = XcodeProjectDriver(logger: Self.logger, configuration: configuration, xcodebuild: xcodebuild, project: scanned, schemes: Set(schemes))
        try driver.build()

        XCTAssertEqual(shell.streamed.count, 1, "\(shell.streamed)", file: file, line: line)
    }

    private struct Builds {
        /// The build commands `build()` ran.
        let builds: Int
        /// The ones `plan()` ran when a reused build proved stale.
        let buildsInPlan: Int
    }

    private static func configuration(_ configurations: [String], buildArguments: [String]) -> Configuration {
        let configuration = Configuration()
        configuration.quiet = true
        configuration.schemes = ["ConfigurationsProject"]
        configuration.configurations = configurations
        configuration.buildArguments = buildArguments
        return configuration
    }

    private static func load(_ path: FilePath, shell: Shell) throws -> XcodeProject {
        var loaded: Set<FilePath> = []
        return try XcodeProject(
            path: path,
            loadedProjectPaths: &loaded,
            xcodebuild: Xcodebuild(shell: shell, logger: logger),
            shell: shell,
            logger: logger
        )
    }

    /// Builds, plans and indexes a new driver's scan of the copy, as a repeated scan does. The driver is released
    /// before the next scan, which would otherwise wait for its lock.
    private func scan(shell: ForwardingRecordingShell, configure: (Configuration) -> Void = { _ in }) throws -> Builds {
        let configuration = Self.configuration([], buildArguments: buildArguments)
        configure(configuration)
        var result: Builds?
        try project.chdir {
            let driver = try XcodeProjectDriver(projectPath: project, configuration: configuration, shell: shell, logger: Self.logger)
            let before = shell.streamed.count
            try driver.build()
            let afterBuild = shell.streamed.count
            Self.plan = try driver.plan(logger: Self.logger.contextualized(with: "index"))
            result = Builds(builds: afterBuild - before, buildsInPlan: shell.streamed.count - afterBuild)
        }
        try Self.index(configuration: configuration)
        return try XCTUnwrap(result)
    }

    /// Declares `name` and calls it from `conditionalEntry()`, which the project's entry point calls.
    private func addCalledFunction(_ name: String) throws {
        try editConditional { text in
            text.replacingOccurrences(of: "    #if DEBUG\n", with: "    \(name)()\n    #if DEBUG\n") + "\nfunc \(name)() {}\n"
        }
    }

    /// Edits in place, which leaves the directory's own date alone.
    private func editConditional(_ edit: (String) -> String) throws {
        let conditional = project.removingLastComponent().appending("ConfigurationsProject/Conditional.swift")
        let text = try String(contentsOf: conditional.url, encoding: .utf8)
        try edit(text).write(to: conditional.url, atomically: false, encoding: .utf8)
    }
}

import Configuration
import Foundation
import Logger
@testable import ProjectDrivers
import Shared
import SourceGraph
import SystemPackage
@testable import TestShared
@testable import XcodeSupport
import XCTest

/// Two projects of a workspace can define targets of the same name; each is its own target, the options name every
/// one of that name or a single one as `Project/Target`, and the unscanned-target logic works per target.
final class XcodeTargetIdentityTest: XCTestCase {
    private static let logger = Logger(quiet: true, verbose: false, colorMode: .never)
    private var root: FilePath!
    private var workspace: XcodeWorkspace!
    private var scannedProject: XcodeProject!
    private var otherProject: XcodeProject!

    /// A workspace of `Scanned.xcodeproj` and `Other.xcodeproj`, copies of one fixture that each define the targets
    /// `ConfigurationsProject` and `ConfigurationsProjectTests`.
    override func setUpWithError() throws {
        root = FilePath(NSTemporaryDirectory()).appending("lethen identity \(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
        for name in ["Scanned", "Other"] {
            let copy = root.appending(name)
            try FileManager.default.copyItem(atPath: ConfigurationsProjectPath.removingLastComponent().string, toPath: copy.string)
            try FileManager.default.moveItem(atPath: copy.appending("ConfigurationsProject.xcodeproj").string, toPath: copy.appending("\(name).xcodeproj").string)
        }
        let workspacePath = root.appending("App.xcworkspace")
        try FileManager.default.createDirectory(atPath: workspacePath.string, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:Scanned/Scanned.xcodeproj"></FileRef>
           <FileRef location = "group:Other/Other.xcodeproj"></FileRef>
        </Workspace>
        """.write(to: workspacePath.appending("contents.xcworkspacedata").url, atomically: true, encoding: .utf8)
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        workspace = try XcodeWorkspace(path: workspacePath, xcodebuild: xcodebuild, configuration: Configuration(), logger: Self.logger, shell: shell)
        scannedProject = try load("Scanned")
        otherProject = try load("Other")
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(atPath: root.string)
        }
    }

    func testSameNamedTargetsOfTwoProjectsAreAllListed() {
        XCTAssertEqual(workspace.targets.count, 4, "\(workspace.targets.map(\.qualifiedName).sorted())")
        XCTAssertEqual(
            workspace.targets.map(\.qualifiedName).sorted(),
            ["Other/ConfigurationsProject", "Other/ConfigurationsProjectTests", "Scanned/ConfigurationsProject", "Scanned/ConfigurationsProjectTests"]
        )
        XCTAssertEqual(workspace.targets.count(where: { $0.name == "ConfigurationsProject" }), 2)
    }

    func testEachTargetKeepsItsOwnFiles() throws {
        try workspace.targets.forEach { try $0.identifyFiles() }

        for (project, directory) in [("Scanned", "Scanned"), ("Other", "Other")] {
            let target = try XCTUnwrap(workspace.targets.first { $0.qualifiedName == "\(project)/ConfigurationsProject" })
            let files = target.files(kind: .swiftSource)
            XCTAssertFalse(files.isEmpty)
            XCTAssertTrue(files.allSatisfy { $0.lexicallyNormalized().starts(with: root.appending(directory).lexicallyNormalized()) }, "\(project): \(files)")
        }
    }

    func testPlainNameMatchesEveryTargetOfThatName() {
        let excluded = workspace.targets.filter { XcodeProjectDriver.isExcluded($0, excludeTests: false, options: ["ConfigurationsProject"]) }

        XCTAssertEqual(excluded.map(\.qualifiedName).sorted(), ["Other/ConfigurationsProject", "Scanned/ConfigurationsProject"])
    }

    func testQualifiedNameMatchesOneTarget() {
        let excluded = workspace.targets.filter { XcodeProjectDriver.isExcluded($0, excludeTests: false, options: ["Other/ConfigurationsProject"]) }

        XCTAssertEqual(excluded.map(\.qualifiedName), ["Other/ConfigurationsProject"])
    }

    func testExcludedTestsAreEveryTestTarget() {
        let excluded = workspace.targets.filter { XcodeProjectDriver.isExcluded($0, excludeTests: true, options: []) }

        XCTAssertEqual(excluded.map(\.qualifiedName).sorted(), ["Other/ConfigurationsProjectTests", "Scanned/ConfigurationsProjectTests"])
    }

    /// The units of a same-named target cannot be told apart by module, so a qualified exclusion leaves out its files.
    func testQualifiedExclusionLeavesOutOnlyTheFilesOfThatTarget() throws {
        try workspace.targets.forEach { try $0.identifyFiles() }
        let options = ["Other/ConfigurationsProject"]
        let excluded = workspace.targets.filter { XcodeProjectDriver.isExcluded($0, excludeTests: false, options: options) }

        let files = XcodeProjectDriver.filesOnlyExcludedTargetsCompile(excluded: excluded, among: workspace.targets, options: options)

        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.allSatisfy { $0.lexicallyNormalized().starts(with: root.appending("Other").lexicallyNormalized()) }, "\(files)")
        XCTAssertTrue(XcodeProjectDriver.filesOnlyExcludedTargetsCompile(excluded: workspace.targets, among: workspace.targets, options: ["ConfigurationsProject"]).isEmpty, "A plain name needs no files")
    }

    /// `Scanned`'s target is indexed and `Other`'s, of the same name, is not.
    func testUnscannedTargetIsFoundAndNamedByItsProject() throws {
        try workspace.targets.forEach { try $0.identifyFiles() }
        let scanned = try XCTUnwrap(workspace.targets.first { $0.qualifiedName == "Scanned/ConfigurationsProject" })
        var indexedModules: [FilePath: Set<String>] = [:]
        for file in scanned.files(kind: .swiftSource) {
            indexedModules[file] = ["ConfigurationsProject"]
        }
        let driver = XcodeProjectDriver(
            logger: Self.logger,
            configuration: Configuration(),
            xcodebuild: Xcodebuild(shell: RecordingShell(), logger: Self.logger),
            project: workspace,
            schemes: ["ConfigurationsProject"]
        )

        let (unscanned, dependencies) = driver.unscannedTargets(among: workspace.targets.filter { $0.name == "ConfigurationsProject" }, indexedModules: indexedModules)

        XCTAssertEqual(unscanned.map(\.name), ["Other/ConfigurationsProject"], "The scanned target is not reported and the name carries its project")
        XCTAssertEqual(dependencies.keys.sorted(), ["Other/ConfigurationsProject"])
        XCTAssertFalse(try XCTUnwrap(unscanned.first).swiftSourceFiles.isEmpty)
    }

    func testUnscannedTargetWarningNamesTheQualifiedTarget() throws {
        let target = UnscannedTarget(name: "Other/ConfigurationsProject", swiftSourceFiles: ["/p/A.swift"], sharedSourceFiles: ["/p/A.swift"])

        let warning = try XCTUnwrap(XcodeProjectDriver.unscannedTargetWarning(for: target, scannedDependencies: []))

        XCTAssertTrue(warning.hasPrefix("Target Other/ConfigurationsProject is in the project but not built"), warning)
        XCTAssertTrue(warning.hasSuffix("--exclude-targets 'Other/ConfigurationsProject' to silence this."), warning)
    }

    /// Declarations carry their module, so `--retain-public-targets Other/ConfigurationsProject` retains that
    /// target's module; a plain name is left as it is.
    func testQualifiedRetainPublicTargetRetainsTheTargetsModule() {
        func retained(_ option: String) -> [String] {
            let configuration = Configuration()
            configuration.retainPublicTargets = [option]
            let driver = XcodeProjectDriver(
                logger: Self.logger,
                configuration: configuration,
                xcodebuild: Xcodebuild(shell: RecordingShell(), logger: Self.logger),
                project: workspace,
                schemes: ["ConfigurationsProject"]
            )
            driver.retainQualifiedPublicTargets(among: workspace.targets)
            return configuration.retainPublicTargets
        }

        XCTAssertEqual(retained("Other/ConfigurationsProject"), ["Other/ConfigurationsProject", "ConfigurationsProject"])
        XCTAssertEqual(retained("ConfigurationsProject"), ["ConfigurationsProject"])
        XCTAssertEqual(retained("Elsewhere/ConfigurationsProject"), ["Elsewhere/ConfigurationsProject"])
    }

    private func load(_ name: String) throws -> XcodeProject {
        var loaded: Set<FilePath> = []
        let shell = RecordingShell()
        return try XcodeProject(
            path: root.appending("\(name)/\(name).xcodeproj"),
            loadedProjectPaths: &loaded,
            xcodebuild: Xcodebuild(shell: shell, logger: Self.logger),
            shell: shell,
            logger: Self.logger
        )
    }
}

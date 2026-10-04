import Configuration
import Foundation
import Logger
@testable import ProjectDrivers
import Shared
import SourceGraph
import SystemPackage
@testable import TestShared
import XcodeProj
@testable import XcodeSupport
import XCTest

/// Two projects of a workspace can define targets of the same name; each is its own target, the options name every
/// one of that name or a single one as `Project/Target`, and the unscanned-target logic works per target.
final class XcodeTargetIdentityTest: XCTestCase {
    private static let logger = Logger(quiet: true, verbose: false, colorMode: .never)
    private var root: FilePath!
    private var workspace: XcodeWorkspace!
    private var scannedProject: XcodeProject!

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

    /// A proxy names the project of the target it depends on; a same-named target of the dependent's own project is
    /// not it. The consumer in `Scanned` depends on `Other/ConfigurationsProject`, which is scanned, not on its own
    /// project's `ConfigurationsProject`, which is not, so it still depends on scanned code.
    func testProxyDependencyResolvesToTheRemoteProjectsTarget() throws {
        try FileManager.default.createDirectory(atPath: root.appending("Scanned").string, withIntermediateDirectories: true)
        try "func consume() {}\n".write(to: root.appending("Scanned/Consumer.swift").url, atomically: true, encoding: .utf8)
        let pbxproj = scannedProject.xcodeProject.pbxproj
        let remote = PBXFileReference(sourceTree: .sourceRoot, name: "Other.xcodeproj", path: "../Other/Other.xcodeproj")
        let proxy = PBXContainerItemProxy(containerPortal: .fileReference(remote), remoteGlobalID: .string("ABCDEF0123456789ABCDEF01"), proxyType: .nativeTarget, remoteInfo: "ConfigurationsProject")
        let dependency = PBXTargetDependency(name: nil, target: nil, targetProxy: proxy)
        let source = PBXFileReference(sourceTree: .sourceRoot, lastKnownFileType: "sourcecode.swift", path: "Consumer.swift")
        let buildFile = PBXBuildFile(file: source)
        let phase = PBXSourcesBuildPhase(files: [buildFile])
        let consumerTarget = PBXNativeTarget(name: "Consumer", buildPhases: [phase], dependencies: [dependency])
        for object in [remote, proxy, dependency, source, buildFile, phase, consumerTarget] as [PBXObject] {
            pbxproj.add(object: object)
        }
        let consumer = XcodeTarget(project: scannedProject, target: consumerTarget)
        XCTAssertEqual(
            consumer.dependencies,
            [XcodeTarget.Dependency(name: "ConfigurationsProject", projectName: "Other", projectPath: root.appending("Other/Other.xcodeproj").lexicallyNormalized())]
        )
        try workspace.targets.forEach { try $0.identifyFiles() }
        try consumer.identifyFiles()

        let other = try XCTUnwrap(workspace.targets.first { $0.qualifiedName == "Other/ConfigurationsProject" })
        var indexedModules: [FilePath: Set<String>] = [:]
        for file in other.files(kind: .swiftSource) {
            indexedModules[file] = ["ConfigurationsProject"]
        }
        let driver = XcodeProjectDriver(
            logger: Self.logger,
            configuration: Configuration(),
            xcodebuild: Xcodebuild(shell: RecordingShell(), logger: Self.logger),
            project: workspace,
            schemes: ["ConfigurationsProject"]
        )

        let (unscanned, dependencies) = driver.unscannedTargets(
            among: Set(workspace.targets.filter { $0.name == "ConfigurationsProject" } + [consumer]),
            indexedModules: indexedModules
        )

        XCTAssertEqual(unscanned.map(\.name), ["Consumer", "Scanned/ConfigurationsProject"])
        XCTAssertEqual(dependencies["Consumer"], ["Other/ConfigurationsProject"])
        XCTAssertEqual(dependencies["Scanned/ConfigurationsProject"], [])
    }

    /// Projects of the same name in different folders share `Project/Target`, so the label falls back to the path.
    func testSameNamedProjectsInDifferentFoldersAreLabelledByPath() throws {
        let nested = root.appending("Nested")
        try FileManager.default.createDirectory(atPath: nested.string, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: root.appending("Scanned").string, toPath: nested.appending("Scanned").string)
        var loaded: Set<FilePath> = []
        let shell = RecordingShell()
        let twin = try XcodeProject(
            path: nested.appending("Scanned/Scanned.xcodeproj"),
            loadedProjectPaths: &loaded,
            xcodebuild: Xcodebuild(shell: shell, logger: Self.logger),
            shell: shell,
            logger: Self.logger
        )
        let targets = Set((scannedProject.targets.union(twin.targets)).filter { $0.name == "ConfigurationsProject" })
        try targets.forEach { try $0.identifyFiles() }
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(Set(targets.map(\.qualifiedName)).count, 1, "Both are Scanned/ConfigurationsProject")
        let driver = XcodeProjectDriver(
            logger: Self.logger,
            configuration: Configuration(),
            xcodebuild: Xcodebuild(shell: shell, logger: Self.logger),
            project: workspace,
            schemes: ["ConfigurationsProject"]
        )

        let (unscanned, dependencies) = driver.unscannedTargets(among: targets, indexedModules: [:])

        XCTAssertEqual(Set(unscanned.map(\.name)).count, 2, "\(unscanned.map(\.name))")
        XCTAssertTrue(unscanned.allSatisfy { $0.name.hasSuffix("/Scanned.xcodeproj/ConfigurationsProject") }, "\(unscanned.map(\.name))")
        XCTAssertEqual(dependencies.count, 2)

        // The warning's own name for one of them excludes that one only.
        let nestedTarget = try XCTUnwrap(targets.first { $0.projectPath.string.contains("/Nested/") })
        let option = try XCTUnwrap(unscanned.first { $0.name.contains("/Nested/") }?.name)
        XCTAssertEqual(nestedTarget.pathQualifiedName, option)
        let excluded = targets.filter { XcodeProjectDriver.isExcluded($0, excludeTests: false, options: [option]) }
        XCTAssertEqual(excluded, [nestedTarget])
        let files = XcodeProjectDriver.filesOnlyExcludedTargetsCompile(excluded: excluded, among: targets, options: [option])
        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.allSatisfy { $0.lexicallyNormalized().starts(with: nested.lexicallyNormalized()) })
    }

    /// Two `Scanned.xcodeproj` in different folders: a proxy names one by its path, so only that one is reached.
    func testProxyDependencyKeepsTheRemoteProjectsPath() throws {
        let nested = root.appending("Nested")
        try FileManager.default.createDirectory(atPath: nested.string, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: root.appending("Scanned").string, toPath: nested.appending("Scanned").string)
        var loaded: Set<FilePath> = []
        let shell = RecordingShell()
        let twin = try XcodeProject(
            path: nested.appending("Scanned/Scanned.xcodeproj"),
            loadedProjectPaths: &loaded,
            xcodebuild: Xcodebuild(shell: shell, logger: Self.logger),
            shell: shell,
            logger: Self.logger
        )
        let consumer = try makeConsumer(in: scannedProject, dependingOn: "ConfigurationsProject", inProjectAt: "../Nested/Scanned/Scanned.xcodeproj")
        let targets = Set(scannedProject.targets.union(twin.targets).filter { $0.name == "ConfigurationsProject" } + [consumer])
        try targets.forEach { try $0.identifyFiles() }
        // The twin in `Nested` is the scanned one; the consumer's project has an unscanned namesake.
        let nestedTarget = try XCTUnwrap(targets.first { $0.projectPath.string.contains("/Nested/") && $0.name == "ConfigurationsProject" })
        let indexedModules = Dictionary(uniqueKeysWithValues: nestedTarget.files(kind: .swiftSource).map { ($0, Set(["ConfigurationsProject"])) })
        let driver = XcodeProjectDriver(
            logger: Self.logger,
            configuration: Configuration(),
            xcodebuild: Xcodebuild(shell: shell, logger: Self.logger),
            project: workspace,
            schemes: ["ConfigurationsProject"]
        )

        let (_, dependencies) = driver.unscannedTargets(among: targets, indexedModules: indexedModules)

        XCTAssertEqual(dependencies["Consumer"], [nestedTarget.pathQualifiedName])
    }

    /// A unit whose module two same-named targets share does not say which of them built a file both compile, so the
    /// target that also compiles a file nothing indexed is still unscanned.
    func testSharedUnitOfASharedModuleDoesNotMakeBothTargetsScanned() throws {
        for (directory, file) in [("Shared", "Shared.swift"), ("Scanned", "OnlyA.swift"), ("Other", "Widget.swift")] {
            try FileManager.default.createDirectory(atPath: root.appending(directory).string, withIntermediateDirectories: true)
            try "func \(file.dropLast(6).lowercased())() {}\n".write(to: root.appending("\(directory)/\(file)").url, atomically: true, encoding: .utf8)
        }
        let a = try makeTarget("Core", in: scannedProject, sources: ["../Shared/Shared.swift", "OnlyA.swift"])
        let b = try makeTarget("Core", in: load("Other"), sources: ["../Shared/Shared.swift", "Widget.swift"])
        let indexed = ["Shared/Shared.swift", "Scanned/OnlyA.swift"].map { root.appending($0).lexicallyNormalized() }
        let driver = XcodeProjectDriver(
            logger: Self.logger,
            configuration: Configuration(),
            xcodebuild: Xcodebuild(shell: RecordingShell(), logger: Self.logger),
            project: workspace,
            schemes: ["Core"]
        )

        let (unscanned, _) = driver.unscannedTargets(among: [a, b], indexedModules: Dictionary(uniqueKeysWithValues: indexed.map { ($0, Set(["Core"])) }))

        XCTAssertEqual(unscanned.map(\.name), ["Other/Core"], "A is scanned through OnlyA.swift; B's Widget.swift has no unit")
        XCTAssertEqual(unscanned.first?.swiftSourceFiles.compactMap { $0.lastComponent?.string }.sorted(), ["Shared.swift", "Widget.swift"])
    }

    private func makeTarget(_ name: String, in project: XcodeProject, sources: [String], dependencies: [PBXTargetDependency] = []) throws -> XcodeTarget {
        let pbxproj = project.xcodeProject.pbxproj
        var objects: [PBXObject] = []
        var buildFiles: [PBXBuildFile] = []
        for path in sources {
            let reference = PBXFileReference(sourceTree: .sourceRoot, lastKnownFileType: "sourcecode.swift", path: path)
            buildFiles.append(PBXBuildFile(file: reference))
            objects.append(reference)
        }
        let phase = PBXSourcesBuildPhase(files: buildFiles)
        let target = PBXNativeTarget(name: name, buildPhases: [phase], dependencies: dependencies)
        for object in objects + buildFiles + [phase] + dependencies + [target] as [PBXObject] {
            pbxproj.add(object: object)
        }
        let result = XcodeTarget(project: project, target: target)
        try result.identifyFiles()
        return result
    }

    /// A target `Consumer` of `project` with a source file and a proxy dependency on `name` in the project at `path`.
    private func makeConsumer(in project: XcodeProject, dependingOn name: String, inProjectAt path: String) throws -> XcodeTarget {
        try "func consume() {}\n".write(to: project.sourceRoot.appending("Consumer.swift").url, atomically: true, encoding: .utf8)
        let pbxproj = project.xcodeProject.pbxproj
        let remote = PBXFileReference(sourceTree: .sourceRoot, name: "Remote.xcodeproj", path: path)
        let proxy = PBXContainerItemProxy(containerPortal: .fileReference(remote), remoteGlobalID: .string("ABCDEF0123456789ABCDEF01"), proxyType: .nativeTarget, remoteInfo: name)
        pbxproj.add(object: remote)
        pbxproj.add(object: proxy)
        let dependency = PBXTargetDependency(name: nil, target: nil, targetProxy: proxy)
        return try makeTarget("Consumer", in: project, sources: ["Consumer.swift"], dependencies: [dependency])
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

import Configuration
import Foundation
import Logger
@testable import ProjectDrivers
import Shared
@testable import SourceGraph
import SyntaxAnalysis
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

        let files = Set(XcodeProjectDriver.excludedUnits(excluded: excluded, among: workspace.targets, options: options).keys)

        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.allSatisfy { $0.lexicallyNormalized().starts(with: root.appending("Other").lexicallyNormalized()) }, "\(files)")
        XCTAssertTrue(XcodeProjectDriver.excludedUnits(excluded: workspace.targets, among: workspace.targets, options: ["ConfigurationsProject"]).isEmpty, "A plain name needs no files")
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
        let files = Set(XcodeProjectDriver.excludedUnits(excluded: excluded, among: targets, options: [option]).keys)
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

    private func writeSources(_ files: [(String, String)]) throws {
        for (directory, file) in files {
            try FileManager.default.createDirectory(atPath: root.appending(directory).string, withIntermediateDirectories: true)
            try "func \(file.dropLast(6).lowercased())() {}\n".write(to: root.appending("\(directory)/\(file)").url, atomically: true, encoding: .utf8)
        }
    }

    private func makeTarget(_ name: String, in project: XcodeProject, sources: [String], module: String? = nil, testTarget: Bool = false, dependencies: [PBXTargetDependency] = []) throws -> XcodeTarget {
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
        if testTarget {
            target.productType = .unitTestBundle
        }
        if let module {
            let debug = XCBuildConfiguration(name: "Debug", buildSettings: ["PRODUCT_MODULE_NAME": .string(module)])
            let list = XCConfigurationList(buildConfigurations: [debug])
            target.buildConfigurationList = list
            objects += [debug, list]
        }
        for object in objects + buildFiles + [phase] + dependencies + [target] as [PBXObject] {
            pbxproj.add(object: object)
        }
        let result = XcodeTarget(project: project, target: target)
        try result.identifyFiles()
        return result
    }

    /// Two targets that compile one file under distinct modules each own their unit, so a file nothing else shares
    /// does not matter: both are scanned.
    func testSharedFileOfDistinctModulesLeavesBothTargetsScanned() throws {
        try writeSources([("Shared", "Shared.swift")])
        let a = try makeTarget("Core", in: scannedProject, sources: ["../Shared/Shared.swift"], module: "ACore")
        let b = try makeTarget("Core", in: load("Other"), sources: ["../Shared/Shared.swift"], module: "BCore")
        let driver = XcodeProjectDriver(logger: Self.logger, configuration: Configuration(), xcodebuild: Xcodebuild(shell: RecordingShell(), logger: Self.logger), project: workspace, schemes: ["Core"])

        let (unscanned, _) = driver.unscannedTargets(among: [a, b], indexedModules: [root.appending("Shared/Shared.swift").lexicallyNormalized(): ["ACore", "BCore"]])

        XCTAssertEqual(unscanned.map(\.name), [])
    }

    /// `Other/Widget` depends on `Other/Core`, which `--exclude-targets Other/Core` leaves out, while `Scanned/Core`
    /// stays scanned: the dependency is not redirected to the namesake.
    func testDependencyOnAnExcludedTargetIsNotRedirectedToANamesake() throws {
        try writeSources([("Scanned", "ScannedCore.swift"), ("Other", "OtherCore.swift"), ("Other", "OtherWidget.swift")])
        let other = try load("Other")
        let core = try makeTarget("Core", in: scannedProject, sources: ["ScannedCore.swift"])
        let excluded = try makeTarget("Core", in: other, sources: ["OtherCore.swift"])
        let remote = PBXFileReference(sourceTree: .sourceRoot, name: "Other.xcodeproj", path: "Other.xcodeproj")
        let proxy = PBXContainerItemProxy(containerPortal: .fileReference(remote), remoteGlobalID: .string("ABCDEF0123456789ABCDEF01"), proxyType: .nativeTarget, remoteInfo: "Core")
        other.xcodeProject.pbxproj.add(object: remote)
        other.xcodeProject.pbxproj.add(object: proxy)
        let dependency = PBXTargetDependency(name: nil, target: nil, targetProxy: proxy)
        let widget = try makeTarget("Widget", in: other, sources: ["OtherWidget.swift"], dependencies: [dependency])
        let driver = XcodeProjectDriver(logger: Self.logger, configuration: Configuration(), xcodebuild: Xcodebuild(shell: RecordingShell(), logger: Self.logger), project: workspace, schemes: ["Core"])
        let options = ["Other/Core"]
        let retained = Set([core, excluded, widget]).filter { !XcodeProjectDriver.isExcluded($0, excludeTests: false, options: options) }

        let (unscanned, dependencies) = driver.unscannedTargets(
            among: retained,
            indexedModules: [root.appending("Scanned/ScannedCore.swift").lexicallyNormalized(): ["Core"]]
        )

        XCTAssertEqual(retained.count, 2)
        XCTAssertEqual(unscanned.map(\.name), ["Widget"])
        XCTAssertEqual(dependencies["Widget"], [], "Its dependency was excluded, and `Scanned/Core` is another target")
    }

    /// A shared file of distinct modules is left out for the excluded target's module only.
    func testQualifiedExclusionOfASharedFileLeavesOutOnlyTheExcludedModule() throws {
        try writeSources([("Shared", "Shared.swift"), ("Other", "OnlyB.swift")])
        let a = try makeTarget("Core", in: scannedProject, sources: ["../Shared/Shared.swift"], module: "ACore")
        let b = try makeTarget("Core", in: load("Other"), sources: ["../Shared/Shared.swift", "OnlyB.swift"], module: "BCore")
        let options = ["Other/Core"]
        let excluded = Set([a, b]).filter { XcodeProjectDriver.isExcluded($0, excludeTests: false, options: options) }

        let units = XcodeProjectDriver.excludedUnits(excluded: excluded, among: [a, b], options: options)

        XCTAssertEqual(units[root.appending("Shared/Shared.swift").lexicallyNormalized()], ["BCore"])
        XCTAssertEqual(units[root.appending("Other/OnlyB.swift").lexicallyNormalized()], [], "A file only the excluded target compiles goes whole")
    }

    /// `--exclude-tests` leaves out a test target `Core` while a production `Core` shares its default module: the module
    /// stays in the index, and the test target's own files are left out by file.
    func testExcludeTestsKeepsTheUnitsOfAProductionTargetThatSharesTheModule() throws {
        try writeSources([("Scanned", "CoreTests.swift"), ("Other", "Core.swift")])
        let tests = try makeTarget("Core", in: scannedProject, sources: ["CoreTests.swift"], testTarget: true)
        let production = try makeTarget("Core", in: load("Other"), sources: ["Core.swift"])
        let targets: Set = [tests, production]
        let excluded = targets.filter { XcodeProjectDriver.isExcluded($0, excludeTests: true, options: []) }

        XCTAssertEqual(excluded, [tests])
        XCTAssertEqual(XcodeProjectDriver.excludedTestModules(excluded: excluded, among: targets), [], "The module `Core` is the production target's too")
        XCTAssertEqual(
            XcodeProjectDriver.excludedUnits(excluded: excluded, among: targets, options: [], excludeTests: true),
            [root.appending("Scanned/CoreTests.swift").lexicallyNormalized(): []]
        )
        // The control: a test target whose module nothing else uses is left out as a module, as before.
        let lone = try makeTarget("LoneTests", in: scannedProject, sources: ["CoreTests.swift"], testTarget: true)
        XCTAssertEqual(XcodeProjectDriver.excludedTestModules(excluded: [lone], among: [lone, production]), ["LoneTests"])
    }

    /// Excluding `Other/Core` leaves its files out of the resource indexes too, while `Scanned/Core`'s stay.
    func testExcludedTargetsFilesAreLeftOutOfTheResourceIndexes() throws {
        try writeSources([("Scanned", "ScannedCore.swift"), ("Other", "OtherCore.swift")])
        let kept = try makeTarget("Core", in: scannedProject, sources: ["ScannedCore.swift"])
        let excluded = try makeTarget("Core", in: load("Other"), sources: ["OtherCore.swift"])

        let files = XcodeProjectDriver.files(ofKind: .swiftSource, in: [kept, excluded], excluding: [excluded])

        XCTAssertEqual(files.compactMap { $0.lastComponent?.string }, ["ScannedCore.swift"])
        XCTAssertEqual(XcodeProjectDriver.files(ofKind: .swiftSource, in: [kept, excluded], excluding: []).count, 2)
    }

    /// `Foo/Core` cannot name one target when two `Foo.xcodeproj` in different folders both define `Core`.
    func testAShortQualifiedNameThatTwoProjectsShareIsRejected() throws {
        try writeSources([("Scanned", "A.swift"), ("Other", "B.swift")])
        let a = try makeTarget("Core", in: scannedProject, sources: ["A.swift"])
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
        let b = try makeTarget("Core", in: twin, sources: ["../Scanned/A.swift"])
        func driver(excluding option: String) -> XcodeProjectDriver {
            let configuration = Configuration()
            configuration.excludeTargets = [option]
            return XcodeProjectDriver(logger: Self.logger, configuration: configuration, xcodebuild: Xcodebuild(shell: shell, logger: Self.logger), project: workspace, schemes: ["Core"])
        }

        XCTAssertThrowsError(try driver(excluding: "Scanned/Core").validateQualifiedTargetOptions(among: [a, b])) { error in
            XCTAssertTrue("\(error)".contains(b.pathQualifiedName), "\(error)")
        }
        XCTAssertNoThrow(try driver(excluding: b.pathQualifiedName).validateQualifiedTargetOptions(among: [a, b]))
        XCTAssertNoThrow(try driver(excluding: "Core").validateQualifiedTargetOptions(among: [a, b]), "A plain name matches both, as documented")
        XCTAssertNoThrow(try driver(excluding: "Other/Core").validateQualifiedTargetOptions(among: [a, b]), "Nothing is ambiguous")
    }

    /// From the targets to the final confidence: the unscanned `Other/Core` uses `Widget`, so `Widget` is reported as
    /// `likely` with the reason naming that target, and a declaration it does not use stays `certain`, though the
    /// scanned `Scanned/Core` has the same name.
    func testUnscannedNamesakeDowngradesWhatItUsesAndNothingElse() throws {
        try writeSources([("Scanned", "ScannedCore.swift")])
        try "let widget = Widget()\n".write(to: root.appending("Other/WidgetUser.swift").url, atomically: true, encoding: .utf8)
        let scanned = try makeTarget("Core", in: scannedProject, sources: ["ScannedCore.swift"])
        let unscannedTarget = try makeTarget("Core", in: load("Other"), sources: ["WidgetUser.swift"])
        let driver = XcodeProjectDriver(logger: Self.logger, configuration: Configuration(), xcodebuild: Xcodebuild(shell: RecordingShell(), logger: Self.logger), project: workspace, schemes: ["Core"])
        let (unscanned, _) = driver.unscannedTargets(among: [scanned, unscannedTarget], indexedModules: [root.appending("Scanned/ScannedCore.swift").lexicallyNormalized(): ["Core"]])
        let target = try XCTUnwrap(unscanned.first)
        XCTAssertEqual(unscanned.map(\.name), ["Other/Core"])

        var evidence = ConfidenceEvidence()
        var sites = NameSites()
        for file in target.swiftSourceFiles.sorted(by: { $0.string < $1.string }) {
            for use in try NameUseCollector.uses(inFileAt: file).uses {
                let site = "\(file.lastComponent?.string ?? ""):\(use.line)"
                sites.names[use.name] = site
                if use.isMember { sites.memberNames[use.name] = site }
                if use.isConstruction { sites.constructionNames[use.name] = site }
            }
        }
        evidence.addUnscannedTargetNames(sites, target: target.name, sharedSourceFiles: target.sharedSourceFiles)
        let graph = SourceGraph(configuration: Configuration(), logger: Self.logger)
        let file = SourceFile(path: root.appending("Scanned/ScannedCore.swift"), modules: ["Core"])
        func declaration(_ name: String, line: Int) -> Declaration {
            let declaration = Declaration(name: name, kind: .struct, usrs: ["s:struct:\(name)"], location: Location(file: file, line: line, column: 1))
            declaration.accessibility = DeclarationAccessibility(value: .public, isExplicit: true)
            return declaration
        }
        let widget = declaration("Widget", line: 1)
        let gadget = declaration("Gadget", line: 2)
        graph.add([widget, gadget])
        let assessor = ConfidenceAssessor(evidence: evidence, graph: graph, configuration: Configuration())

        let named = assessor.assess(widget)
        XCTAssertEqual(named.confidence, .likely)
        XCTAssertTrue(named.reason?.hasSuffix("a file of target Other/Core, which the scanned schemes do not build") == true, named.reason ?? "nil")
        XCTAssertEqual(assessor.assess(gadget).confidence, .certain, "The control: nothing in `Other/Core` names it")
    }

    /// The build is the costly step, so an ambiguous `Project/Target` option stops the scan before it starts.
    func testAmbiguousQualifiedOptionStopsBeforeTheBuild() throws {
        let nested = root.appending("Nested")
        try FileManager.default.createDirectory(atPath: nested.string, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: root.appending("Scanned").string, toPath: nested.appending("Scanned").string)
        let workspacePath = root.appending("Twins.xcworkspace")
        try FileManager.default.createDirectory(atPath: workspacePath.string, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:Scanned/Scanned.xcodeproj"></FileRef>
           <FileRef location = "group:Nested/Scanned/Scanned.xcodeproj"></FileRef>
        </Workspace>
        """.write(to: workspacePath.appending("contents.xcworkspacedata").url, atomically: true, encoding: .utf8)
        let shell = RecordingShell()
        let xcodebuild = Xcodebuild(shell: shell, logger: Self.logger)
        let configuration = Configuration()
        configuration.excludeTargets = ["Scanned/ConfigurationsProject"]
        let twins = try XcodeWorkspace(path: workspacePath, xcodebuild: xcodebuild, configuration: configuration, logger: Self.logger, shell: shell)
        let driver = XcodeProjectDriver(logger: Self.logger, configuration: configuration, xcodebuild: xcodebuild, project: twins, schemes: ["ConfigurationsProject"])

        XCTAssertThrowsError(try driver.build())
        XCTAssertTrue(shell.streamed.isEmpty, "\(shell.streamed)")
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

import Configuration
import Foundation
import Indexer
import Logger
@testable import ProjectDrivers
import Shared
import SystemPackage
@testable import TestShared
@testable import XcodeSupport
import XCTest

/// `--skip-build` without `--index-store-path` finds the index Xcode keeps for the project in its own
/// DerivedData, and refuses it when sources were edited after they were indexed.
final class XcodeIndexDiscoveryTest: XCTestCase {
    private var root: FilePath!
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    override func setUpWithError() throws {
        root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen xcode index \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root.url)
        }
    }

    // MARK: - Locator

    func testLocatorMatchesTheProjectAndPrefersTheMostRecentlyWrittenStore() throws {
        let project = root.appending("App/App.xcodeproj")
        let derivedData = root.appending("DerivedData")
        let older = try makeDerivedData(named: "App-older", workspace: project, in: derivedData, written: Date(timeIntervalSinceNow: -3600))
        let newer = try makeDerivedData(named: "App-newer", workspace: project, in: derivedData, written: Date())
        _ = try makeDerivedData(named: "Other-newest", workspace: root.appending("Other/Other.xcodeproj"), in: derivedData, written: Date(timeIntervalSinceNow: 60))

        let stores = XcodeDerivedDataLocator(root: derivedData).indexStores(for: project)

        XCTAssertEqual(stores, [newer, older])
    }

    func testLocatorResolvesSymlinksInTheRecordedWorkspacePath() throws {
        let real = root.appending("Real")
        try FileManager.default.createDirectory(at: real.appending("App.xcodeproj").url, withIntermediateDirectories: true)
        let link = root.appending("Link")
        try FileManager.default.createSymbolicLink(at: link.url, withDestinationURL: real.url)
        let derivedData = root.appending("DerivedData")
        let store = try makeDerivedData(named: "App-link", workspace: link.appending("App.xcodeproj"), in: derivedData, written: Date())

        XCTAssertEqual(XcodeDerivedDataLocator(root: derivedData).indexStores(for: real.appending("App.xcodeproj")), [store])
    }

    func testLocatorSkipsDirectoriesWithoutAnInfoPlistOrAnIndex() throws {
        let project = root.appending("App/App.xcodeproj")
        let derivedData = root.appending("DerivedData")
        try FileManager.default.createDirectory(at: derivedData.appending("NoInfo/Index.noindex/DataStore/v5/units").url, withIntermediateDirectories: true)
        let noIndex = derivedData.appending("NoIndex")
        try FileManager.default.createDirectory(at: noIndex.url, withIntermediateDirectories: true)
        try writeInfoPlist(workspace: project, to: noIndex)

        XCTAssertEqual(XcodeDerivedDataLocator(root: derivedData).indexStores(for: project), [])
        XCTAssertEqual(XcodeDerivedDataLocator(root: root.appending("Missing")).indexStores(for: project), [])
    }

    // MARK: - Driver

    func testSkipBuildUsesXcodesIndexAndRejectsSourcesEditedAfterIndexing() throws {
        let fixture = SwiftUIProjectPath.removingLastComponent()
        let copy = root.appending("SwiftUIProject")
        try FileManager.default.copyItem(at: fixture.url, to: copy.url)
        let project = copy.appending("SwiftUIProject.xcodeproj")
        let derivedData = root.appending("DerivedData")
        let shell = ShellImpl(logger: logger)
        // What Xcode does when it builds the project: its DerivedData gets an info.plist naming the project.
        try shell.exec([
            "xcodebuild", "-project", project.string, "-scheme", "SwiftUIProject",
            "-derivedDataPath", derivedData.appending("SwiftUIProject-discovery").string,
            "-quiet", "build-for-testing", "CODE_SIGNING_ALLOWED=NO",
        ])

        let configuration = Configuration()
        configuration.schemes = ["SwiftUIProject"]
        configuration.skipBuild = true
        let driver = try makeDriver(project: project, configuration: configuration, shell: shell, derivedData: derivedData)

        var plan: IndexPlan?
        try project.removingLastComponent().chdir {
            plan = try driver.plan(logger: logger.contextualized(with: "test"))
        }

        let app = copy.appending("SwiftUIProject/App.swift")
        let planned = try XCTUnwrap(plan).sourceFiles.keys.map { resolved($0.path) }
        XCTAssertTrue(planned.contains(resolved(app)), "The plan must come from the copy's Xcode index, got \(planned)")

        // Edited after Xcode indexed it: the store is refused rather than used silently.
        let text = try String(contentsOf: app.url, encoding: .utf8)
        try (text + "\n// edited after indexing\n").write(to: app.url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try project.removingLastComponent().chdir { _ = try driver.plan(logger: logger.contextualized(with: "test")) }) { error in
            guard case let LethenError.staleIndexStore(_, staleFiles) = error else {
                return XCTFail("Expected a stale index error, got \(error)")
            }

            XCTAssertEqual(staleFiles.map { FilePath($0).lastComponent?.string }, ["App.swift"])
        }
    }

    func testDerivedDataPathVerifiesAPipelineBuildThatIndexStorePathDoesNot() throws {
        let fixture = SwiftUIProjectPath.removingLastComponent()
        let copy = root.appending("SwiftUIProject")
        try FileManager.default.copyItem(at: fixture.url, to: copy.url)
        let project = copy.appending("SwiftUIProject.xcodeproj")
        let pipeline = root.appending("Pipeline")
        let shell = ShellImpl(logger: logger)
        try shell.exec([
            "xcodebuild", "-project", project.string, "-scheme", "SwiftUIProject",
            "-derivedDataPath", pipeline.string,
            "-quiet", "build-for-testing", "CODE_SIGNING_ALLOWED=NO",
        ])

        // The locator's root is empty, so only the given path can lead to the store.
        let emptyRoot = root.appending("EmptyDerivedData")
        try FileManager.default.createDirectory(at: emptyRoot.url, withIntermediateDirectories: true)

        let configuration = Configuration()
        configuration.schemes = ["SwiftUIProject"]
        configuration.skipBuild = true
        configuration.derivedDataPath = pipeline
        let driver = try makeDriver(project: project, configuration: configuration, shell: shell, derivedData: emptyRoot)

        var plan: IndexPlan?
        try project.removingLastComponent().chdir {
            plan = try driver.plan(logger: logger.contextualized(with: "test"))
        }

        let app = copy.appending("SwiftUIProject/App.swift")
        let planned = try XCTUnwrap(plan).sourceFiles.keys.map { resolved($0.path) }
        XCTAssertTrue(planned.contains(resolved(app)), "The plan must come from the pipeline's index, got \(planned)")

        let text = try String(contentsOf: app.url, encoding: .utf8)
        try (text + "\n// edited after indexing\n").write(to: app.url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try project.removingLastComponent().chdir { _ = try driver.plan(logger: logger.contextualized(with: "test")) }) { error in
            guard case let LethenError.staleIndexStore(_, staleFiles) = error else {
                return XCTFail("Expected a stale index error, got \(error)")
            }

            XCTAssertEqual(staleFiles.map { FilePath($0).lastComponent?.string }, ["App.swift"])
        }

        // Control: the same store passed with `--index-store-path` stays authoritative and unchecked.
        let explicit = Configuration()
        explicit.schemes = ["SwiftUIProject"]
        explicit.skipBuild = true
        explicit.indexStorePath = [pipeline.appending("Index.noindex/DataStore")]
        let explicitDriver = try makeDriver(project: project, configuration: explicit, shell: shell, derivedData: emptyRoot)
        var explicitPlan: IndexPlan?
        try project.removingLastComponent().chdir {
            explicitPlan = try explicitDriver.plan(logger: logger.contextualized(with: "test"))
        }

        let explicitPlanned = try XCTUnwrap(explicitPlan).sourceFiles.keys.map { resolved($0.path) }
        XCTAssertTrue(explicitPlanned.contains(resolved(app)), "An explicit store is read as given, got \(explicitPlanned)")
    }

    func testDerivedDataPathWithoutAnIndexIsAnError() throws {
        let fixture = SwiftUIProjectPath.removingLastComponent()
        let copy = root.appending("SwiftUIProject")
        try FileManager.default.copyItem(at: fixture.url, to: copy.url)
        let project = copy.appending("SwiftUIProject.xcodeproj")
        let empty = root.appending("Empty")
        try FileManager.default.createDirectory(at: empty.url, withIntermediateDirectories: true)

        let configuration = Configuration()
        configuration.schemes = ["SwiftUIProject"]
        configuration.skipBuild = true
        configuration.derivedDataPath = empty
        let driver = try makeDriver(project: project, configuration: configuration, shell: ShellImpl(logger: logger), derivedData: root.appending("DerivedData"))

        XCTAssertThrowsError(try project.removingLastComponent().chdir { _ = try driver.plan(logger: logger.contextualized(with: "test")) }) { error in
            guard case let LethenError.indexStoreNotFound(derivedDataPath) = error else {
                return XCTFail("Expected indexStoreNotFound, got \(error)")
            }

            XCTAssertEqual(derivedDataPath, empty.string)
        }
    }

    /// A compilation-cache hit writes no index unit. A store in which a file of an indexed target has no unit is refused
    /// rather than scanned with that file's references missing.
    func testSkipBuildRejectsAStoreMissingAUnitOfAnIndexedTarget() throws {
        let built = try buildSwiftUIProject()
        try removeUnits(ofSourceFilesNamed: ["App.swift"], from: built.store)

        let configuration = Configuration()
        configuration.schemes = ["SwiftUIProject"]
        configuration.skipBuild = true
        let driver = try makeDriver(project: built.project, configuration: configuration, shell: built.shell, derivedData: built.derivedData)

        XCTAssertThrowsError(try built.project.removingLastComponent().chdir { _ = try driver.plan(logger: logger.contextualized(with: "test")) }) { error in
            guard case let LethenError.incompleteIndexStore(path, missingFiles) = error else {
                return XCTFail("Expected an incomplete index error, got \(error)")
            }

            XCTAssertEqual(missingFiles.map { FilePath($0).lastComponent?.string }, ["App.swift"])
            XCTAssertEqual(resolved(FilePath(path)), resolved(built.store))
        }

        // Control: an explicit store stays authoritative, so the same store plans, without the file that has no unit.
        let explicit = Configuration()
        explicit.schemes = ["SwiftUIProject"]
        explicit.indexStorePath = [built.store]
        let explicitDriver = try makeDriver(project: built.project, configuration: explicit, shell: built.shell, derivedData: built.derivedData)
        var plan: IndexPlan?
        try built.project.removingLastComponent().chdir {
            plan = try explicitDriver.plan(logger: logger.contextualized(with: "test"))
        }

        let planned = try XCTUnwrap(plan).sourceFiles.keys.map { resolved($0.path).lastComponent?.string }
        XCTAssertFalse(planned.contains("App.swift"), "\(planned)")
        XCTAssertTrue(planned.contains("ContentView.swift"), "The other units must still be read, got \(planned)")
    }

    /// Lethen cannot tell a target the schemes do not build from one the compilation cache skipped, so a target without
    /// a single unit is left to the partial-store handling it always had.
    func testSkipBuildStillAcceptsAStoreWithoutAnyUnitOfATarget() throws {
        // SwiftUIProject has one target, so removing every unit leaves that target with none.
        let built = try buildSwiftUIProject()
        try removeUnits(ofSourceFilesNamed: nil, from: built.store)

        let configuration = Configuration()
        configuration.schemes = ["SwiftUIProject"]
        configuration.skipBuild = true
        let driver = try makeDriver(project: built.project, configuration: configuration, shell: built.shell, derivedData: built.derivedData)

        var plan: IndexPlan?
        try built.project.removingLastComponent().chdir {
            plan = try driver.plan(logger: logger.contextualized(with: "test"))
        }

        XCTAssertTrue(try XCTUnwrap(plan).sourceFiles.isEmpty)
    }

    /// `SharedBetweenTargets.swift` is compiled by the built target and by `UnscannedTool`, which the scheme does not
    /// build. The unit belongs to the built target's module, so the unbuilt target has no unit of its own: its
    /// `UnscannedMain.swift` is not a missing unit, and the store is accepted.
    func testSkipBuildAcceptsAStoreWhoseUnbuiltTargetSharesAFileWithABuiltOne() throws {
        let copy = root.appending("MixedLanguageProject")
        try FileManager.default.copyItem(at: MixedLanguageProjectPath.removingLastComponent().url, to: copy.url)
        let project = copy.appending("MixedLanguageProject.xcodeproj")
        let derivedData = root.appending("DerivedData")
        let shell = ShellImpl(logger: logger)
        try shell.exec([
            "xcodebuild", "-project", project.string, "-scheme", "MixedLanguageProject",
            "-derivedDataPath", derivedData.appending("MixedLanguageProject-discovery").string,
            "-quiet", "build-for-testing", "CODE_SIGNING_ALLOWED=NO",
        ])

        let configuration = Configuration()
        configuration.schemes = ["MixedLanguageProject"]
        configuration.skipBuild = true
        let driver = try makeDriver(project: project, configuration: configuration, shell: shell, derivedData: derivedData, schemes: ["MixedLanguageProject"])

        var plan: IndexPlan?
        try project.removingLastComponent().chdir {
            plan = try driver.plan(logger: logger.contextualized(with: "test"))
        }

        let planned = try XCTUnwrap(plan).sourceFiles.keys.map { resolved($0.path).lastComponent?.string }
        XCTAssertTrue(planned.contains("SharedBetweenTargets.swift"), "\(planned)")
        XCTAssertFalse(planned.contains("UnscannedMain.swift"), "\(planned)")
    }

    // MARK: - Private

    /// Copies SwiftUIProject and builds it into a DerivedData of its own, as Xcode does.
    private func buildSwiftUIProject() throws -> (project: FilePath, derivedData: FilePath, store: FilePath, shell: Shell) {
        let copy = root.appending("SwiftUIProject")
        try FileManager.default.copyItem(at: SwiftUIProjectPath.removingLastComponent().url, to: copy.url)
        let project = copy.appending("SwiftUIProject.xcodeproj")
        let derivedData = root.appending("DerivedData")
        let shell = ShellImpl(logger: logger)
        let directory = derivedData.appending("SwiftUIProject-discovery")
        try shell.exec([
            "xcodebuild", "-project", project.string, "-scheme", "SwiftUIProject",
            "-derivedDataPath", directory.string,
            "-quiet", "build-for-testing", "CODE_SIGNING_ALLOWED=NO",
        ])
        return (project, derivedData, directory.appending("Index.noindex/DataStore"), shell)
    }

    /// Deletes the unit files of the named source files, or of every file when `names` is nil. A unit file's name starts
    /// with its source file's name, such as `App.swift-<hash>`.
    private func removeUnits(ofSourceFilesNamed names: [String]?, from store: FilePath) throws {
        let units = store.appending("v5/units")
        let all = try FileManager.default.contentsOfDirectory(atPath: units.string)
        // A unit is named after the compiled file, `App.swift-<hash>` or `App.o-<hash>` depending on the build system.
        let doomed = all.filter { unit in names?.contains { unit.hasPrefix(FilePath($0).stem! + ".") } ?? true }
        XCTAssertFalse(doomed.isEmpty, "No unit of \(names ?? ["any file"]) in \(all)")
        for unit in doomed {
            try FileManager.default.removeItem(atPath: units.appending(unit).string)
        }
    }

    private func resolved(_ path: FilePath) -> FilePath {
        FilePath(path.url.resolvingSymlinksInPath().path)
    }

    private func makeDriver(project: FilePath, configuration: Configuration, shell: Shell, derivedData: FilePath, schemes: Set<String> = ["SwiftUIProject"]) throws -> XcodeProjectDriver {
        let xcodebuild = Xcodebuild(shell: shell, logger: logger)
        var loaded: Set<FilePath> = []
        let xcodeProject = try XcodeProject(path: project, loadedProjectPaths: &loaded, xcodebuild: xcodebuild, shell: shell, logger: logger)
        return XcodeProjectDriver(
            logger: logger,
            configuration: configuration,
            xcodebuild: xcodebuild,
            project: xcodeProject,
            schemes: schemes,
            derivedDataLocator: XcodeDerivedDataLocator(root: derivedData)
        )
    }

    private func makeDerivedData(named name: String, workspace: FilePath, in derivedData: FilePath, written: Date) throws -> FilePath {
        let directory = derivedData.appending(name)
        let units = directory.appending("Index.noindex/DataStore/v5/units")
        try FileManager.default.createDirectory(at: units.url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: units.string)
        try writeInfoPlist(workspace: workspace, to: directory)
        return directory.appending("Index.noindex/DataStore")
    }

    private func writeInfoPlist(workspace: FilePath, to directory: FilePath) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": workspace.string], format: .xml, options: 0)
        try data.write(to: directory.appending("info.plist").url)
    }
}

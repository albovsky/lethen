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
            "xcodebuild", "-project", "'\(project.string)'", "-scheme", "SwiftUIProject",
            "-derivedDataPath", "'\(derivedData.appending("SwiftUIProject-discovery").string)'",
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

    // MARK: - Private

    private func resolved(_ path: FilePath) -> FilePath {
        FilePath(path.url.resolvingSymlinksInPath().path)
    }

    private func makeDriver(project: FilePath, configuration: Configuration, shell: Shell, derivedData: FilePath) throws -> XcodeProjectDriver {
        let xcodebuild = Xcodebuild(shell: shell, logger: logger)
        var loaded: Set<FilePath> = []
        let xcodeProject = try XcodeProject(path: project, loadedProjectPaths: &loaded, xcodebuild: xcodebuild, shell: shell, logger: logger)
        return XcodeProjectDriver(
            logger: logger,
            configuration: configuration,
            xcodebuild: xcodebuild,
            project: xcodeProject,
            schemes: ["SwiftUIProject"],
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

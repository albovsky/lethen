import Foundation
import Logger
import Shared
import SystemPackage
@testable import TestShared
@testable import XcodeSupport
import XCTest

final class XcodeTargetTest: XCTestCase {
    private var project: XcodeProject!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let shell = ShellImpl(logger: logger)
        let xcodebuild = Xcodebuild(shell: shell, logger: logger)
        var loadedProjectPaths: Set<FilePath> = []
        project = try XcodeProject(
            path: UIKitProjectPath,
            loadedProjectPaths: &loadedProjectPaths,
            xcodebuild: xcodebuild,
            shell: shell,
            logger: logger
        )
    }

    override func tearDown() {
        project = nil
        super.tearDown()
    }

    func testSourceFileInGroupWithoutFolder() throws {
        let target = try XCTUnwrap(project.targets.first { $0.name == "UIKitProject" })
        try target.identifyFiles()

        XCTAssertTrue(target.files(kind: .interfaceBuilder).contains {
            $0.relativeTo(ProjectRootPath).string == "Tests/XcodeTests/UIKitProject/UIKitProject/FileInGroupWithoutFolder.xib"
        })
    }

    func testIdentifiesSwiftAndClangSourceFiles() throws {
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let shell = ShellImpl(logger: logger)
        var loadedProjectPaths: Set<FilePath> = []
        let mixed = try XcodeProject(
            path: MixedLanguageProjectPath,
            loadedProjectPaths: &loadedProjectPaths,
            xcodebuild: Xcodebuild(shell: shell, logger: logger),
            shell: shell,
            logger: logger
        )
        let target = try XCTUnwrap(mixed.targets.first { $0.name == "MixedLanguageProject" })
        try target.identifyFiles()

        let clangNames = target.files(kind: .clangSource).compactMap { $0.lastComponent?.string }
        let swiftNames = target.files(kind: .swiftSource).compactMap { $0.lastComponent?.string }
        XCTAssertTrue(clangNames.contains("ObjCCaller.m"), "\(clangNames.sorted())")
        XCTAssertFalse(clangNames.contains("ObjCCaller.h"), "Headers are not compiled into a unit")
        XCTAssertTrue(swiftNames.contains("ObjCExposed.swift"), "\(swiftNames.sorted())")
        XCTAssertFalse(swiftNames.contains("ObjCCaller.m"))
    }

    /// A synchronized folder compiles its sources only into the targets that own it.
    func testSynchronizedFolderSourcesBelongToTheirOwningTarget() throws {
        let owner = try XCTUnwrap(project.targets.first { $0.name == "UIKitProject" })
        let other = try XCTUnwrap(project.targets.first { $0.name == "UIKitProjectTests" })
        try owner.identifyFiles()
        try other.identifyFiles()

        let folder = UIKitProjectPath.removingLastComponent().appending("UIKitProject/FileSystemFolder")
        let synchronized = folder.appending("SynchronizedFolderSource.swift")
        XCTAssertTrue(owner.files(kind: .swiftSource).contains(synchronized), "\(owner.files(kind: .swiftSource).sorted())")
        XCTAssertFalse(other.files(kind: .swiftSource).contains(synchronized))
        // Resources keep the project-wide behavior.
        XCTAssertTrue(owner.files(kind: .interfaceBuilder).contains(folder.appending("XibViewController3.xib")))
    }

    func testIsTestTarget() throws {
        let projectTarget = try XCTUnwrap(project.targets.first { $0.name == "UIKitProject" })
        let testTarget = try XCTUnwrap(project.targets.first { $0.name == "UIKitProjectTests" })

        XCTAssertFalse(projectTarget.isTestTarget)
        XCTAssertTrue(testTarget.isTestTarget)
    }
}

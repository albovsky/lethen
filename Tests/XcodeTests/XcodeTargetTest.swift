import Foundation
import Logger
import Shared
import SystemPackage
@testable import TestShared
import XcodeProj
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
        XCTAssertTrue(owner.files(kind: .interfaceBuilder).contains(folder.appending("XibViewController3.xib")))
    }

    /// Resources of a synchronized folder, like its sources, belong only to the target that owns it.
    func testSynchronizedFolderResourcesBelongToTheirOwningTarget() throws {
        let app = try XCTUnwrap(project.targets.first { $0.name == "UIKitProject" })
        let extra = try XCTUnwrap(project.targets.first { $0.name == "Target With Spaces" })
        try app.identifyFiles()
        try extra.identifyFiles()
        let appFolder = UIKitProjectPath.removingLastComponent().appending("UIKitProject/FileSystemFolder")
        let extraFolder = UIKitProjectPath.removingLastComponent().appending("UIKitProject/ExtraFolder")

        XCTAssertTrue(extra.files(kind: .interfaceBuilder).contains(extraFolder.appending("Extra.storyboard")), "\(extra.files(kind: .interfaceBuilder).sorted())")
        XCTAssertFalse(app.files(kind: .interfaceBuilder).contains(extraFolder.appending("Extra.storyboard")), "The app does not own ExtraFolder")
        XCTAssertTrue(app.files(kind: .interfaceBuilder).contains(appFolder.appending("XibViewController3.xib")))
        XCTAssertFalse(extra.files(kind: .interfaceBuilder).contains(appFolder.appending("XibViewController3.xib")), "ExtraFolder's owner does not own FileSystemFolder")
    }

    /// A file ticked for a target in a folder another target owns belongs to both: the exception set for the folder
    /// names the including target and lists the file.
    func testExceptionSetOfAnotherTargetsFolderIncludesTheFilesItListsInThisTarget() throws {
        let app = try XCTUnwrap(project.targets.first { $0.name == "UIKitProject" })
        let owner = try XCTUnwrap(project.targets.first { $0.name == "Target With Spaces" })
        try app.identifyFiles()
        try owner.identifyFiles()
        let folder = UIKitProjectPath.removingLastComponent().appending("UIKitProject/InclusionFolder")

        XCTAssertTrue(app.files(kind: .swiftSource).contains(folder.appending("Shared.swift")), "\(app.files(kind: .swiftSource).sorted())")
        XCTAssertTrue(app.files(kind: .interfaceBuilder).contains(folder.appending("Inclusion.storyboard")), "\(app.files(kind: .interfaceBuilder).sorted())")
        XCTAssertTrue(owner.files(kind: .swiftSource).contains(folder.appending("Shared.swift")), "The owner keeps what the exception set includes elsewhere")
        XCTAssertTrue(owner.files(kind: .interfaceBuilder).contains(folder.appending("Inclusion.storyboard")))
    }

    /// An included entry that names a folder takes the files below it along, as an exclusion does.
    func testExceptionSetOfAnotherTargetsFolderIncludesTheFilesBelowAListedFolder() throws {
        let app = try XCTUnwrap(project.targets.first { $0.name == "UIKitProject" })
        try app.identifyFiles()
        let folder = UIKitProjectPath.removingLastComponent().appending("UIKitProject/InclusionFolder")

        XCTAssertTrue(app.files(kind: .swiftSource).contains(folder.appending("Nested/Inner.swift")), "\(app.files(kind: .swiftSource).sorted())")
        XCTAssertFalse(app.files(kind: .swiftSource).contains(folder.appending("Other/OtherInner.swift")), "A folder the exception set does not list")
    }

    /// The control: a file of that folder the exception set does not list stays out of the including target, and
    /// the exception set does not turn into exclusions for the owner.
    func testExceptionSetOfAnotherTargetsFolderLeavesOutTheFilesItDoesNotList() throws {
        let app = try XCTUnwrap(project.targets.first { $0.name == "UIKitProject" })
        let owner = try XCTUnwrap(project.targets.first { $0.name == "Target With Spaces" })
        try app.identifyFiles()
        try owner.identifyFiles()
        let folder = UIKitProjectPath.removingLastComponent().appending("UIKitProject/InclusionFolder")

        XCTAssertFalse(app.files(kind: .swiftSource).contains(folder.appending("NotListed.swift")))
        XCTAssertTrue(owner.files(kind: .swiftSource).contains(folder.appending("NotListed.swift")))
        XCTAssertFalse(app.files(kind: .swiftSource).contains(folder.appending("Missing.swift")))
    }

    /// A membership exception leaves a file out of its target's resources as well as its sources.
    func testMembershipExceptionLeavesAPlistOutOfTheTargetsInfoPlists() throws {
        let app = try XCTUnwrap(project.targets.first { $0.name == "UIKitProject" })
        let extra = try XCTUnwrap(project.targets.first { $0.name == "Target With Spaces" })
        try app.identifyFiles()
        try extra.identifyFiles()
        let extraFolder = UIKitProjectPath.removingLastComponent().appending("UIKitProject/ExtraFolder")

        XCTAssertTrue(extra.files(kind: .infoPlist).contains(extraFolder.appending("Extra.plist")), "\(extra.files(kind: .infoPlist).sorted())")
        XCTAssertFalse(extra.files(kind: .infoPlist).contains(extraFolder.appending("Excluded.plist")), "Left out by the folder's membership exceptions for this target")
        XCTAssertFalse(extra.files(kind: .infoPlist).contains(extraFolder.appending("Hidden/Hidden.plist")), "An exception that names a folder takes the files below it along")
        XCTAssertFalse(app.files(kind: .infoPlist).contains(extraFolder.appending("Extra.plist")))
        XCTAssertTrue(extra.files(kind: .infoPlist).contains { $0.lastComponent?.string == "Info.plist" }, "The INFOPLIST_FILE setting still counts")
    }

    func testIsTestTarget() throws {
        let projectTarget = try XCTUnwrap(project.targets.first { $0.name == "UIKitProject" })
        let testTarget = try XCTUnwrap(project.targets.first { $0.name == "UIKitProjectTests" })

        XCTAssertFalse(projectTarget.isTestTarget)
        XCTAssertTrue(testTarget.isTestTarget)
    }

    func testDependenciesIncludeTargetsOfOtherProjectsThroughTheirProxy() throws {
        let local = try XCTUnwrap(project.xcodeProject.pbxproj.nativeTargets.first { $0.name == "UIKitProject" })
        let proxy = PBXContainerItemProxy(containerPortal: .project(project.xcodeProject.pbxproj.rootObject!), remoteGlobalID: .string("ABCDEF0123456789ABCDEF01"), proxyType: .nativeTarget, remoteInfo: "RemoteFramework")
        let dependencies = [
            PBXTargetDependency(name: nil, target: local, targetProxy: nil),
            PBXTargetDependency(name: nil, target: nil, targetProxy: proxy),
        ]
        let pbxTarget = PBXNativeTarget(name: "Consumer", dependencies: dependencies)
        // References resolve through the project's object graph, as they do for a parsed project.
        let pbxproj = project.xcodeProject.pbxproj
        pbxproj.add(object: proxy)
        dependencies.forEach { pbxproj.add(object: $0) }
        pbxproj.add(object: pbxTarget)
        let target = XcodeTarget(project: project, target: pbxTarget)

        XCTAssertEqual(Set(target.dependencies.map(\.name)), ["UIKitProject", "RemoteFramework"])
    }

    /// Linking a project target's product is an implicit dependency, which Xcode honors without a
    /// `PBXTargetDependency`.
    func testDependenciesIncludeLinkedProductsOfProjectTargets() throws {
        let framework = try XCTUnwrap(project.xcodeProject.pbxproj.nativeTargets.first { $0.name == "Target With Spaces" })
        let product = try XCTUnwrap(framework.product)
        let buildFile = PBXBuildFile(file: product)
        let phase = PBXFrameworksBuildPhase(files: [buildFile])
        let pbxTarget = PBXNativeTarget(name: "Linker", buildPhases: [phase])
        let pbxproj = project.xcodeProject.pbxproj
        pbxproj.add(object: buildFile)
        pbxproj.add(object: phase)
        pbxproj.add(object: pbxTarget)

        XCTAssertEqual(Set(XcodeTarget(project: project, target: pbxTarget).dependencies.map(\.name)), ["Target With Spaces"])
    }

    func testModuleNamesAreTheConfiguredProductModuleNamesOrTheDefault() throws {
        // Each configuration may name the module differently; a unit could come from any of them.
        let debug = XCBuildConfiguration(name: "Debug", buildSettings: ["PRODUCT_MODULE_NAME": .string("DebugCore")])
        let release = XCBuildConfiguration(name: "Release", buildSettings: ["PRODUCT_MODULE_NAME": .string("ReleaseCore")])
        let list = XCConfigurationList(buildConfigurations: [debug, release])
        XCTAssertEqual(XcodeTarget(project: project, target: PBXNativeTarget(name: "Core", buildConfigurationList: list)).moduleNames, ["DebugCore", "ReleaseCore"])

        let variable = XCBuildConfiguration(name: "Debug", buildSettings: ["PRODUCT_MODULE_NAME": .string("$(TARGET_NAME:c99extidentifier)")])
        let variableList = XCConfigurationList(buildConfigurations: [variable])
        XCTAssertEqual(XcodeTarget(project: project, target: PBXNativeTarget(name: "Target With Spaces", buildConfigurationList: variableList)).moduleNames, ["Target_With_Spaces"])

        XCTAssertEqual(XcodeTarget.defaultModuleName(forTarget: "3D-Kit"), "_3D_Kit")
        XCTAssertEqual(try XCTUnwrap(project.targets.first { $0.name == "Target With Spaces" }).moduleNames, ["Target_With_Spaces"])
    }
}

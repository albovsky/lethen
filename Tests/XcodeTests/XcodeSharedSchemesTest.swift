import Foundation
import SystemPackage
@testable import TestShared
@testable import XcodeSupport
import XCTest

final class XcodeSharedSchemesTest: XCTestCase {
    func testListsTheSharedSchemesOfTheFixtureProjects() {
        XCTAssertEqual(XcodeSharedSchemes.names(in: [UIKitProjectPath]), ["Scheme With Spaces", "UIKitProject"])
        XCTAssertEqual(XcodeSharedSchemes.names(in: [SwiftUIProjectPath]), ["SwiftUIProject"])
        XCTAssertEqual(XcodeSharedSchemes.names(in: [ConfigurationsProjectPath]), ["ConfigurationsProject", "ReleaseTests"])
    }

    func testUnionsContainersAndCountsASharedNameOnce() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let workspace = try Self.container("App.xcworkspace", schemes: ["Shared", "WorkspaceOnly"], in: root)
        let project = try Self.container("App.xcodeproj", schemes: ["Shared", "ProjectOnly"], in: root)

        XCTAssertEqual(XcodeSharedSchemes.names(in: [workspace, project]), ["Shared", "ProjectOnly", "WorkspaceOnly"].sorted())
        XCTAssertEqual(XcodeSharedSchemes.names(in: [project, workspace]), ["Shared", "ProjectOnly", "WorkspaceOnly"].sorted())
    }

    func testIgnoresPodsProjects() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let pods = try Self.container("Pods.xcodeproj", schemes: ["Alamofire"], in: root)
        let app = try Self.container("App.xcodeproj", schemes: ["App"], in: root)

        XCTAssertEqual(XcodeSharedSchemes.names(in: [pods, app]), ["App"])
        XCTAssertEqual(XcodeSharedSchemes.names(in: [pods]), [])
    }

    func testAContainerWithoutSharedDataContributesNothing() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let bare = root.appending("Bare.xcodeproj")
        try FileManager.default.createDirectory(atPath: bare.string, withIntermediateDirectories: true)

        XCTAssertEqual(XcodeSharedSchemes.names(in: [bare]), [])
        XCTAssertEqual(XcodeSharedSchemes.names(in: [root.appending("Missing.xcodeproj")]), [])
        XCTAssertEqual(XcodeSharedSchemes.names(in: []), [])
    }

    func testIgnoresFilesThatAreNotSchemes() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let project = try Self.container("App.xcodeproj", schemes: ["App"], in: root)
        let directory = project.appending("xcshareddata/xcschemes")
        try Data().write(to: directory.appending("xcschememanagement.plist").url)
        try Data().write(to: directory.appending("Notes.txt").url)

        XCTAssertEqual(XcodeSharedSchemes.names(in: [project]), ["App"])
    }

    // MARK: - Helpers

    private static func makeRoot() throws -> FilePath {
        let root = FilePath(FileManager.default.temporaryDirectory.path).appending("lethen-schemes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
        return root
    }

    private static func container(_ name: String, schemes: [String], in root: FilePath) throws -> FilePath {
        let container = root.appending(name)
        let directory = container.appending("xcshareddata/xcschemes")
        try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
        for scheme in schemes {
            try Data().write(to: directory.appending("\(scheme).xcscheme").url)
        }
        return container
    }
}

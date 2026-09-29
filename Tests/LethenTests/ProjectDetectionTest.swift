import Foundation
@testable import Frontend
import Shared
import SystemPackage
import XCTest

final class ProjectDetectionTest: XCTestCase {
    private var directory: FilePath!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lethen-detect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = FilePath(url.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: directory.string)
        try super.tearDownWithError()
    }

    // MARK: - Nothing to detect

    func testEmptyDirectoryDetectsNothing() throws {
        XCTAssertNil(try detect())
    }

    func testNestedProjectsAreNotDetected() throws {
        try makeProject("Examples/Demo.xcodeproj")
        try makeProject("Pods/Pods.xcodeproj")

        XCTAssertNil(try detect())
    }

    func testFileNamedLikeAProjectIsNotDetected() throws {
        try write("", to: "Notes.xcodeproj")

        XCTAssertNil(try detect())
    }

    func testLegacyBazelWorkspaceIsNotDetected() throws {
        try write("", to: "WORKSPACE")

        XCTAssertNil(try detect())
    }

    // MARK: - Swift packages

    func testPackageWinsOverAnXcodeProject() throws {
        try write("// swift-tools-version:6.0\n", to: "Package.swift")
        try makeProject("App.xcodeproj")
        try write("", to: "MODULE.bazel")

        XCTAssertEqual(try detect(), .spm)
    }

    // MARK: - Xcode

    func testSingleProjectIsDetected() throws {
        try makeProject("App.xcodeproj")
        try makeProject("Examples/Demo.xcodeproj")

        XCTAssertEqual(try detect(), .xcode(directory.appending("App.xcodeproj")))
    }

    func testTopLevelPodsProjectIsIgnored() throws {
        try makeProject("App.xcodeproj")
        try makeProject("Pods.xcodeproj")

        XCTAssertEqual(try detect(), .xcode(directory.appending("App.xcodeproj")))
    }

    func testHiddenProjectIsIgnored() throws {
        try makeProject("App.xcodeproj")
        try makeProject(".build/Other.xcodeproj")
        try makeProject(".Hidden.xcodeproj")

        XCTAssertEqual(try detect(), .xcode(directory.appending("App.xcodeproj")))
    }

    func testWorkspaceReferencingTheProjectIsPreferred() throws {
        try makeProject("App.xcodeproj")
        try makeProject("Pods/Pods.xcodeproj")
        try makeWorkspace("App.xcworkspace", references: ["group:App.xcodeproj", "group:Pods/Pods.xcodeproj"])

        XCTAssertEqual(try detect(), .xcode(directory.appending("App.xcworkspace")))
    }

    func testSingleWorkspaceIsDetected() throws {
        try makeWorkspace("App.xcworkspace", references: ["group:Sources/App.xcodeproj"])

        XCTAssertEqual(try detect(), .xcode(directory.appending("App.xcworkspace")))
    }

    func testWorkspaceNotReferencingTheProjectIsAmbiguous() throws {
        try makeProject("App.xcodeproj")
        try makeProject("Tool.xcodeproj")
        try makeWorkspace("App.xcworkspace", references: ["group:App.xcodeproj"])

        try assertUsageError(options: ["--project App.xcworkspace", "--project Tool.xcodeproj"])
    }

    func testSeveralProjectsAreAmbiguous() throws {
        try makeProject("App.xcodeproj")
        try makeProject("My App.xcodeproj")

        try assertUsageError(
            prefix: "Found several Xcode projects in the current directory.",
            options: ["--project App.xcodeproj", "--project \"My App.xcodeproj\""]
        )
    }

    func testSeveralWorkspacesAreAmbiguous() throws {
        try makeProject("App.xcodeproj")
        try makeWorkspace("App.xcworkspace", references: ["group:App.xcodeproj"])
        try makeWorkspace("Other.xcworkspace", references: ["group:App.xcodeproj"])

        try assertUsageError(options: ["--project App.xcworkspace", "--project Other.xcworkspace", "--project App.xcodeproj"])
    }

    // MARK: - Bazel

    func testBazelModuleIsDetected() throws {
        try write("module(name = \"app\")\n", to: "MODULE.bazel")
        try makeProject("Examples/Demo.xcodeproj")

        XCTAssertEqual(try detect(), .bazel)
    }

    func testBazelModuleBesideAnXcodeProjectIsAmbiguous() throws {
        try write("", to: "MODULE.bazel")
        try makeProject("App.xcodeproj")

        try assertUsageError(
            prefix: "Found both a Bazel module and an Xcode project in the current directory.",
            options: ["--bazel", "--project App.xcodeproj"]
        )
    }

    // MARK: - Workspace references

    func testWorkspaceReferencesResolveThroughGroups() {
        let contents = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace
           version = "1.0">
           <FileRef
              location = "group:App.xcodeproj">
           </FileRef>
           <Group
              location = "group:Modules"
              name = "Modules">
              <FileRef
                 location = "group:Core/Core.xcodeproj">
              </FileRef>
              <Group location = "group:" name = "Empty"/>
              <FileRef location = "group:Kit.xcodeproj"/>
           </Group>
           <FileRef location = "container:Tools/Tool.xcodeproj"/>
           <FileRef location = "absolute:/opt/Shared.xcodeproj"/>
           <FileRef location = "group:R&amp;D.xcodeproj"/>
           <FileRef location = "group:README.md"/>
        </Workspace>
        """

        let paths = ProjectDetector.referencedProjectPaths(inWorkspaceContents: contents, sourceRoot: "/repo")

        XCTAssertEqual(paths, [
            "/repo/App.xcodeproj",
            "/repo/Modules/Core/Core.xcodeproj",
            "/repo/Modules/Kit.xcodeproj",
            "/repo/Tools/Tool.xcodeproj",
            "/opt/Shared.xcodeproj",
            "/repo/R&D.xcodeproj",
        ])
    }

    // MARK: - Private

    private func detect() throws -> ProjectDetector.Detection? {
        try ProjectDetector(directory: directory).detect()
    }

    private func assertUsageError(prefix: String? = nil, options: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try detect(), file: file, line: line) { error in
            guard case let .usageError(message) = error as? LethenError else {
                return XCTFail("Expected a usage error, got: \(error)", file: file, line: line)
            }

            var lines = message.components(separatedBy: "\n")
            let heading = lines.removeFirst()
            if let prefix {
                XCTAssertTrue(heading.hasPrefix(prefix), heading, file: file, line: line)
            }
            XCTAssertEqual(lines, options.map { "  \($0)" }, file: file, line: line)
        }
    }

    private func makeProject(_ path: String) throws {
        try write("// !$*UTF8*$!\n{}\n", to: "\(path)/project.pbxproj")
    }

    private func makeWorkspace(_ path: String, references: [String]) throws {
        let fileRefs = references.map { "   <FileRef\n      location = \"\($0)\">\n   </FileRef>" }
        let contents = (["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<Workspace\n   version = \"1.0\">"] + fileRefs + ["</Workspace>"])
            .joined(separator: "\n")
        try write(contents, to: "\(path)/contents.xcworkspacedata")
    }

    private func write(_ contents: String, to path: String) throws {
        let url = URL(fileURLWithPath: directory.appending(path).string)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

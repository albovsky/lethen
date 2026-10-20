import Foundation
import Logger
import Shared
import SystemPackage
@testable import XcodeSupport
import XCTest

/// Xcode 27.2 can store a project as JSON in `project.xcproj` instead of `project.pbxproj`. XcodeProj reads only the
/// latter, so a project with only the JSON file stops with an error that names the format, and one that still has
/// `project.pbxproj` loads from it.
final class XcodeProjectFormatTest: XCTestCase {
    private var root: FilePath!

    override func setUpWithError() throws {
        root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen-format-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(atPath: root.string)
        }
    }

    func testProjectInTheJSONFormatOnlyIsAnErrorNamingTheFormat() throws {
        let project = root.appending("App.xcodeproj")
        try FileManager.default.createDirectory(atPath: project.string, withIntermediateDirectories: true)
        try "{}\n".write(toFile: project.appending("project.xcproj").string, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try load(project)) { error in
            guard case let LethenError.usageError(message) = error else { return XCTFail("\(error)") }

            XCTAssertTrue(message.contains("project.xcproj"), message)
            XCTAssertTrue(message.contains("JSON project format"), message)
        }
    }

    func testProjectWithAPropertyListFileLoadsFromIt() throws {
        let project = root.appending("UIKitProject.xcodeproj")
        try FileManager.default.copyItem(atPath: UIKitProjectPath.string, toPath: project.string)
        try "{}\n".write(toFile: project.appending("project.xcproj").string, atomically: true, encoding: .utf8)

        XCTAssertFalse(try load(project).targets.isEmpty)
    }

    private func load(_ project: FilePath) throws -> XcodeProject {
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let shell = ShellMock(output: "")
        var loadedProjectPaths: Set<FilePath> = []
        return try XcodeProject(
            path: project,
            loadedProjectPaths: &loadedProjectPaths,
            xcodebuild: Xcodebuild(shell: shell, logger: logger),
            shell: shell,
            logger: logger
        )
    }
}

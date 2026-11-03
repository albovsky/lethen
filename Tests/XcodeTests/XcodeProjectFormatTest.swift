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

    func testScanOfAProjectConvertedByXcodeReportsTheUnsupportedFormat() throws {
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        // The Swift 6.4 CI job selects Xcode 27.0 but also has 27.2 installed alongside it.
        let sideBySide = FilePath("/Applications/Xcode_27.2.app/Contents/Developer")
        let environment = sideBySide.exists ? ["env", "DEVELOPER_DIR=\(sideBySide)"] : []
        let xcodebuild = environment + ["/usr/bin/xcodebuild"]
        let version = try shell.exec(xcodebuild + ["-version"])
        let number = try XCTUnwrap(version.split(separator: "\n").first?.split(separator: " ").last)
        try XCTSkipUnless(String(number).isVersion(greaterThanOrEqualTo: "27.2"), "Conversion requires Xcode 27.2 or later; found \(version)")

        let copy = root.appending("Fixture")
        try FileManager.default.copyItem(atPath: ConfigurationsProjectPath.removingLastComponent().string, toPath: copy.string)
        let project = copy.appending("ConfigurationsProject.xcodeproj")
        try shell.exec(xcodebuild + ["-project", project.string, "-convert-project", "xcproj"])
        XCTAssertTrue(project.appending("project.xcproj").exists)
        XCTAssertFalse(project.appending("project.pbxproj").exists)
        let listing = try shell.exec(xcodebuild + ["-project", project.string, "-list", "-json"])
        XCTAssertTrue(listing.contains("\"ConfigurationsProject\""), listing)

        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("lethen")
        let scan = [executable.path, "scan", "--project-root", copy.string, "--project", project.string, "--schemes", "ConfigurationsProject", "--disable-update-check"]
        XCTAssertThrowsError(try shell.exec(environment + scan)) { error in
            guard case let LethenError.shellCommandFailed(_, _, output) = error else { return XCTFail("\(error)") }

            XCTAssertTrue(output.contains("JSON project format (project.xcproj)"), output)
            print("\(version)\n\(output)")
        }
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

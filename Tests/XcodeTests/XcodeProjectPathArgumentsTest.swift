import Configuration
import Foundation
import Logger
@testable import ProjectDrivers
import Shared
import Synchronization
import SystemPackage
@testable import TestShared
@testable import XcodeSupport
import XCTest

/// Project paths, scheme names and build arguments reach `xcodebuild` as data. A project whose path holds shell syntax
/// is inspected like any other, and the syntax never runs.
final class XcodeProjectPathArgumentsTest: XCTestCase {
    private final class RecordingShell: Shell {
        private let commands = Mutex<[[String]]>([])

        var all: [[String]] {
            commands.withLock { $0 }
        }

        func exec(_ args: [String]) throws -> String {
            commands.withLock { $0.append(args) }
            return args.contains("-list")
                ? #"{"project": {"name": "Demo", "schemes": ["My App"], "targets": []}}"#
                : "Xcode 27.0\nBuild version 27A266a"
        }

        func execStatus(_: [String]) throws -> Int32 {
            0
        }
    }

    private var root: FilePath!
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen project path \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root.url)
        }
        try super.tearDownWithError()
    }

    /// The reproduction of the reported injection: `--skip-build` lists the schemes of a project named with command
    /// substitutions, which used to run them.
    func testSkipBuildListsSchemesOfAProjectWhosePathHoldsShellSyntax() throws {
        let fixture = SwiftUIProjectPath.removingLastComponent()
        let copy = root.appending("SwiftUIProject")
        try FileManager.default.copyItem(at: fixture.url, to: copy.url)
        let project = copy.appending("Demo $(touch INJECTED) `touch TICKED`.xcodeproj")
        try FileManager.default.moveItem(at: copy.appending("SwiftUIProject.xcodeproj").url, to: project.url)

        let configuration = Configuration()
        configuration.schemes = ["SwiftUIProject"]
        configuration.skipBuild = true
        var driver: XcodeProjectDriver?
        try root.chdir {
            driver = try XcodeProjectDriver(projectPath: project, configuration: configuration, shell: ShellImpl(logger: logger), logger: logger)
        }

        XCTAssertNotNil(driver, "Scheme validation must succeed for the unusual path")
        for marker in ["INJECTED", "TICKED"] {
            XCTAssertFalse(root.appending(marker).exists, "\(marker) was created, so the project path ran as shell code")
            XCTAssertFalse(copy.appending(marker).exists, "\(marker) was created, so the project path ran as shell code")
        }
    }

    func testSchemeListingPassesThePathAndArgumentsAsSeparateArguments() throws {
        let shell = RecordingShell()
        let path = "/Projects/My $(App) `x` \"quoted\" 'single'.xcodeproj"

        let schemes = try Xcodebuild(shell: shell, logger: logger).schemes(
            type: "project",
            path: path,
            additionalArguments: ["-destination", "platform=iOS Simulator,name=iPhone 17"]
        )

        XCTAssertEqual(schemes, ["My App"])
        XCTAssertEqual(shell.all, [["xcodebuild", "-project", path, "-list", "-json", "-destination", "platform=iOS Simulator,name=iPhone 17"]])
    }

    func testSchemeListingOfAPlainPathIsUnchanged() throws {
        let shell = RecordingShell()

        _ = try Xcodebuild(shell: shell, logger: logger).schemes(type: "workspace", path: "/Projects/App.xcworkspace", additionalArguments: [])

        XCTAssertEqual(shell.all, [["xcodebuild", "-workspace", "/Projects/App.xcworkspace", "-list", "-json"]])
    }

    func testBuildPassesSchemeSettingsAndBuildArgumentsUnquoted() throws {
        var loaded: Set<FilePath> = []
        let loadingShell = ShellImpl(logger: logger)
        let project = try XcodeProject(
            path: SwiftUIProjectPath,
            loadedProjectPaths: &loaded,
            xcodebuild: Xcodebuild(shell: loadingShell, logger: logger),
            shell: loadingShell,
            logger: logger
        )
        let shell = RecordingShell()

        try Xcodebuild(shell: shell, logger: logger).build(
            project: project,
            scheme: "My $(App)",
            allSchemes: ["My $(App)"],
            additionalArguments: ["-destination", "platform=macOS", "OTHER_SWIFT_FLAGS=-DA -DB"]
        )

        let build = try XCTUnwrap(shell.all.first { $0.contains("build-for-testing") })
        XCTAssertEqual(Array(build.prefix(5)), ["xcodebuild", "-project", SwiftUIProjectPath.lexicallyNormalized().string, "-scheme", "My $(App)"])
        let derivedData = try XCTUnwrap(build.firstIndex(of: "-derivedDataPath").map { build[$0 + 1] })
        XCTAssertTrue(derivedData.hasPrefix("/"), derivedData)
        XCTAssertFalse(derivedData.contains("'"), derivedData)
        XCTAssertTrue(build.contains("CODE_SIGNING_ALLOWED=NO"))
        XCTAssertTrue(build.contains("COMPILER_INDEX_STORE_ENABLE=YES"))
        XCTAssertEqual(Array(build.suffix(3)), ["-destination", "platform=macOS", "OTHER_SWIFT_FLAGS=-DA -DB"])
    }
}

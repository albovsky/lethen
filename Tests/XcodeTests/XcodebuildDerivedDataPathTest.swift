import Foundation
import Logger
import Shared
import Synchronization
import SystemPackage
@testable import XcodeSupport
import XCTest

final class XcodebuildDerivedDataPathTest: XCTestCase {
    private final class RecordingShell: Shell {
        private let commands = Mutex<[[String]]>([])
        private let streamedCommands = Mutex<[[String]]>([])

        var streamed: [[String]] {
            streamedCommands.withLock { $0 }
        }

        var derivedDataPaths: [String] {
            commands.withLock { commands in
                commands.compactMap { command in
                    guard command.first == "xcodebuild", let index = command.firstIndex(of: "-derivedDataPath") else { return nil }

                    return command[index + 1]
                }
            }
        }

        func exec(_ args: [String]) throws -> String {
            commands.withLock { $0.append(args) }
            return "Xcode 27.0\nBuild version 27A266a"
        }

        func exec(_ args: [String], onOutputLine: @escaping @Sendable (String) -> Void) throws -> String {
            streamedCommands.withLock { $0.append(args) }
            onOutputLine("note: Building targets in dependency order")
            return try exec(args)
        }

        func execStatus(_: [String]) throws -> Int32 {
            0
        }
    }

    private var project: XcodeProject!
    private var shell: RecordingShell!
    private var xcodebuild: Xcodebuild!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        var loadedProjectPaths: Set<FilePath> = []
        let loadingShell = ShellImpl(logger: logger)
        let loadingXcodebuild = Xcodebuild(shell: loadingShell, logger: logger)
        project = try XcodeProject(path: UIKitProjectPath, loadedProjectPaths: &loadedProjectPaths, xcodebuild: loadingXcodebuild, shell: loadingShell, logger: logger)
        shell = RecordingShell()
        xcodebuild = Xcodebuild(shell: shell, logger: logger)
    }

    override func tearDown() {
        project = nil
        shell = nil
        xcodebuild = nil
        super.tearDown()
    }

    func testDerivedDataPathDoesNotDependOnSchemeOrder() throws {
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["B", "A"])
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A", "B"])
        let paths = shell.derivedDataPaths
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths.first, paths.last)
    }

    func testDerivedDataPathDependsOnTheSetOfSchemes() throws {
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A", "B"])
        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A", "C"])
        let paths = shell.derivedDataPaths
        XCTAssertEqual(paths.count, 2)
        XCTAssertNotEqual(paths.first, paths.last)
    }

    func testBuildStreamsOnlyTheBuildCommand() throws {
        let lines = Mutex<[String]>([])

        try xcodebuild.build(project: project, scheme: "A", allSchemes: ["A"]) { line in lines.withLock { $0.append(line) } }

        XCTAssertEqual(shell.streamed.count, 1)
        XCTAssertEqual(shell.streamed.first?.first, "xcodebuild")
        XCTAssertEqual(shell.streamed.first?.contains("build-for-testing"), true)
        XCTAssertEqual(lines.withLock { $0 }, ["note: Building targets in dependency order"])
    }
}

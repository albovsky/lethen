import Configuration
import Foundation
import Logger
@testable import ProjectDrivers
import Shared
import SystemPackage
@testable import TestShared
@testable import XcodeSupport
import XCTest

/// A scan without `--schemes` builds the project's only shared scheme, and otherwise stops with the schemes to pass.
final class XcodeSchemeAutopickTest: XCTestCase {
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    // MARK: - Choosing the scheme

    func testPicksTheOnlySharedSchemeWithoutListing() throws {
        var listed = false
        let scheme = try XcodeProjectDriver.defaultScheme(for: Stub(shared: ["App"])) {
            listed = true
            return ["Other"]
        }

        XCTAssertEqual(scheme, "App")
        XCTAssertFalse(listed)
    }

    func testSeveralSharedSchemesAreListedSortedAndQuoted() throws {
        var listed = false
        XCTAssertThrowsError(try XcodeProjectDriver.defaultScheme(for: Stub(shared: ["A", "B", "C D"])) {
            listed = true
            return []
        }) { error in
            XCTAssertEqual(
                Self.message(error),
                "The '--schemes' option is required: Wikipedia.xcodeproj shares several schemes. Pass one or more of: A, B, 'C D'."
            )
        }
        XCTAssertFalse(listed)
    }

    func testNoSharedSchemeListsWhatXcodebuildListed() {
        XCTAssertThrowsError(try XcodeProjectDriver.defaultScheme(for: Stub(shared: [])) { ["B", "A"] }) { error in
            XCTAssertEqual(
                Self.message(error),
                "The '--schemes' option is required: Wikipedia.xcodeproj shares no scheme. Pass one or more of the schemes xcodebuild lists: A, B."
            )
        }
    }

    func testNoSchemeAnywhereSaysHowToShareOne() {
        XCTAssertThrowsError(try XcodeProjectDriver.defaultScheme(for: Stub(shared: [])) { [] }) { error in
            let message = Self.message(error)
            XCTAssertTrue(message?.contains("shares no scheme and xcodebuild lists none") == true, "\(String(describing: message))")
            XCTAssertTrue(message?.contains("Product > Scheme > Manage Schemes") == true, "\(String(describing: message))")
        }
    }

    // MARK: - Driver

    func testDriverBuildsTheOnlySharedScheme() throws {
        let shell = RecordingShell(listedSchemes: ["SwiftUIProject"])
        let driver = try makeDriver(SwiftUIProjectPath, schemes: [], shell: shell)

        try driver.build()

        let command = try XCTUnwrap(shell.streamed.first)
        XCTAssertEqual(shell.streamed.count, 1)
        XCTAssertEqual(command.first, "xcodebuild")
        let index = try XCTUnwrap(command.firstIndex(of: "-scheme"))
        XCTAssertEqual(command[index + 1], "SwiftUIProject")
    }

    func testDriverStopsWhenSeveralSchemesAreShared() {
        let shell = RecordingShell(listedSchemes: ["ConfigurationsProject", "ReleaseTests"])
        XCTAssertThrowsError(try makeDriver(ConfigurationsProjectPath, schemes: [], shell: shell)) { error in
            guard case LethenError.usageError = error else { return XCTFail("\(error)") }

            XCTAssertTrue(Self.message(error)?.contains("ConfigurationsProject, ReleaseTests") == true, "\(String(describing: Self.message(error)))")
        }
        XCTAssertTrue(shell.streamed.isEmpty)
    }

    /// An explicit choice wins over the autopick, even where several schemes are shared.
    func testExplicitSchemeStillBuildsExactlyThatScheme() throws {
        let shell = RecordingShell(listedSchemes: ["ConfigurationsProject", "ReleaseTests"])
        let driver = try makeDriver(ConfigurationsProjectPath, schemes: ["ReleaseTests"], shell: shell)

        try driver.build()

        let command = try XCTUnwrap(shell.streamed.first)
        XCTAssertEqual(shell.streamed.count, 1)
        let index = try XCTUnwrap(command.firstIndex(of: "-scheme"))
        XCTAssertEqual(command[index + 1], "ReleaseTests")
    }

    func testExplicitUnknownSchemeIsStillInvalid() {
        let shell = RecordingShell(listedSchemes: ["ConfigurationsProject", "ReleaseTests"])
        XCTAssertThrowsError(try makeDriver(ConfigurationsProjectPath, schemes: ["Nope"], shell: shell)) { error in
            guard case let LethenError.invalidScheme(name, _) = error else { return XCTFail("\(error)") }

            XCTAssertEqual(name, "Nope")
        }
    }

    func testSkippedValidationPicksTheSchemeWithoutListing() throws {
        let shell = RecordingShell()
        let driver = try makeDriver(SwiftUIProjectPath, schemes: [], shell: shell) { $0.skipSchemesValidation = true }

        try driver.build()

        XCTAssertFalse(shell.executed.contains { $0.contains("-list") }, "\(shell.executed)")
        let command = try XCTUnwrap(shell.streamed.first)
        let index = try XCTUnwrap(command.firstIndex(of: "-scheme"))
        XCTAssertEqual(command[index + 1], "SwiftUIProject")
    }

    // MARK: - Helpers

    private func makeDriver(
        _ path: FilePath,
        schemes: [String],
        shell: RecordingShell,
        _ adjust: (Configuration) -> Void = { _ in }
    ) throws -> XcodeProjectDriver {
        let configuration = Configuration()
        configuration.quiet = true
        configuration.schemes = schemes
        adjust(configuration)
        return try XcodeProjectDriver(projectPath: path, configuration: configuration, shell: shell, logger: logger)
    }

    private static func message(_ error: Error) -> String? {
        guard case let LethenError.usageError(message) = error else { return nil }

        return message
    }
}

private final class Stub: XcodeProjectlike {
    let path = FilePath("/work/Wikipedia.xcodeproj")
    let targets: Set<XcodeTarget> = []
    let type = "project"
    let sourceRoot = FilePath("/work")
    let buildConfigurationNames: Set<String> = []
    let sharedSchemes: [String]

    init(shared: [String]) {
        sharedSchemes = shared
    }

    func schemes(additionalArguments _: [String]) throws -> Set<String> { [] }
    func schemeConfigurations(named _: String) -> XcodeSchemeConfigurations? { nil }
}

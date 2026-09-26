import ArgumentParser
@testable import Configuration
import Foundation
@testable import Frontend
import Logger
import Shared
import SystemPackage
import XCTest

final class ScanCommandConfigurationTest: XCTestCase {
    /// Settings that only the configuration file can set.
    private static let configurationFileOnlyKeys: Set = ["xcode_list_arguments"]
    /// Command properties that steer the command itself rather than a setting.
    private static let commandOnlyProperties: Set = ["setup", "project_root", "config", "no_color"]

    private var originalDirectory: FilePath!
    private var projectRoot: FilePath!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalDirectory = FilePath.current
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lethen-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        projectRoot = FilePath(url.path)
    }

    override func tearDownWithError() throws {
        _ = FileManager.default.changeCurrentDirectoryPath(originalDirectory.string)
        try? FileManager.default.removeItem(atPath: projectRoot.string)
        try super.tearDownWithError()
    }

    // MARK: - Option mapping

    func testEverySettingIsAppliedFromItsOwnOption() throws {
        let settings = Configuration().settings.filter { !Self.configurationFileOnlyKeys.contains($0.key) }
        XCTAssertFalse(settings.isEmpty)

        for setting in settings {
            let arguments = try XCTUnwrap(commandLineArguments(for: setting), setting.key)
            let configuration = try makeConfiguration(arguments)
            let changedKeys = configuration.settings.filter(\.hasNonDefaultValue).map(\.key)
            XCTAssertEqual(changedKeys, [setting.key], "\(arguments.joined(separator: " ")) must set only '\(setting.key)'")
        }
    }

    func testEveryCommandPropertyIsASetting() throws {
        let settingKeys = Set(Configuration().settings.map(\.key))
        let properties = try Mirror(reflecting: ScanCommand.parse([])).children.compactMap(\.label)
        XCTAssertFalse(properties.isEmpty)

        for property in properties {
            let key = snakeCased(property.hasPrefix("_") ? String(property.dropFirst()) : property)
            XCTAssertTrue(
                settingKeys.contains(key) || Self.commandOnlyProperties.contains(key),
                "The '\(property)' option has no setting named '\(key)'"
            )
        }
    }

    func testNoColorForcesNeverOverColorOption() throws {
        let configuration = try makeConfiguration(["--color", "always", "--no-color"])
        XCTAssertEqual(configuration.color, .never)
    }

    func testCommandSetsProjectRootAndGuidedSetup() throws {
        let configuration = try makeConfiguration(["--setup"])
        XCTAssertEqual(configuration.projectRoot, projectRoot)
        XCTAssertTrue(configuration.guidedSetup)
        XCTAssertEqual(FilePath.current.lastComponent, projectRoot.lastComponent)
    }

    func testProjectRootDefaultsToBazelWorkspaceDirectory() throws {
        setenv("BUILD_WORKSPACE_DIRECTORY", projectRoot.string, 1)
        defer { unsetenv("BUILD_WORKSPACE_DIRECTORY") }

        XCTAssertEqual(try ScanCommand.parse([]).projectRoot, projectRoot)
    }

    func testProjectRootDefaultsToCurrentDirectory() throws {
        unsetenv("BUILD_WORKSPACE_DIRECTORY")

        XCTAssertEqual(try ScanCommand.parse([]).projectRoot, FilePath.current)
    }

    func testMissingProjectRootIsAnError() throws {
        let missing = projectRoot.appending("missing")
        XCTAssertThrowsError(try ScanCommand.parse(["--project-root", missing.string]).makeConfiguration()) { error in
            guard case let .changeCurrentDirectoryFailed(path) = error as? LethenError else {
                return XCTFail("Expected changeCurrentDirectoryFailed, got: \(error)")
            }

            XCTAssertEqual(path, missing)
        }
    }

    func testIndexStorePathImpliesSkipBuild() throws {
        let configuration = try makeConfiguration(["--index-store-path", projectRoot.appending("store").string])
        XCTAssertFalse(configuration.skipBuild)
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let shell = VersionShell()
        let project = Project(
            kind: .generic(genericProjectConfig: projectRoot.appending("missing.json")),
            configuration: configuration,
            shell: shell,
            logger: logger
        )

        // The missing generic configuration stops the scan right after the implication is applied.
        XCTAssertThrowsError(try Scan(configuration: configuration, logger: logger, swiftVersion: SwiftVersion(shell: shell)).perform(project: project))
        XCTAssertTrue(configuration.skipBuild)
    }

    // MARK: - Configuration file

    func testConfigurationFileIsLoaded() throws {
        try writeConfigurationFile(at: projectRoot.appending(".periphery.yml"))

        let configuration = try makeConfiguration([])
        XCTAssertTrue(configuration.retainPublic)
        XCTAssertEqual(configuration.outputFormat, .json)
    }

    func testCommandLineOverridesConfigurationFile() throws {
        try writeConfigurationFile(at: projectRoot.appending(".periphery.yml"))

        let configuration = try makeConfiguration(["--format", "csv"])
        XCTAssertTrue(configuration.retainPublic)
        XCTAssertEqual(configuration.outputFormat, .csv)
    }

    func testConfigOptionLoadsAnotherFile() throws {
        try writeConfigurationFile(at: projectRoot.appending(".periphery.yml"), format: "checkstyle")
        try writeConfigurationFile(at: projectRoot.appending("other.yml"))

        let configuration = try makeConfiguration(["--config", "other.yml"])
        XCTAssertEqual(configuration.outputFormat, .json)
    }

    func testMissingConfigFileIsAnError() throws {
        XCTAssertThrowsError(try makeConfiguration(["--config", "missing.yml"])) { error in
            guard case let .pathDoesNotExist(path) = error as? LethenError else {
                return XCTFail("Expected pathDoesNotExist, got: \(error)")
            }

            XCTAssertEqual(path, "missing.yml")
        }
    }

    func testGuidedSetupSkipsConfigurationFile() throws {
        try writeConfigurationFile(at: projectRoot.appending(".periphery.yml"))

        let configuration = try makeConfiguration(["--setup"])
        XCTAssertFalse(configuration.retainPublic)
        XCTAssertEqual(configuration.outputFormat, .default)
    }

    // MARK: - Private

    private struct VersionShell: Shell {
        func exec(_: [String]) throws -> String {
            "Swift version 6.3 (swift-6.3-RELEASE)"
        }

        func execStatus(_: [String]) throws -> Int32 {
            0
        }
    }

    private func makeConfiguration(_ arguments: [String]) throws -> Configuration {
        try ScanCommand.parse(["--project-root", projectRoot.string] + arguments).makeConfiguration()
    }

    private func writeConfigurationFile(at path: FilePath, format: String = "json") throws {
        try "retain_public: true\nformat: \(format)\n".write(toFile: path.string, atomically: true, encoding: .utf8)
    }

    /// Command-line arguments that set `setting` to a value other than its default, derived from the
    /// setting's key and type so that a new setting is covered without editing this test.
    private func commandLineArguments(for setting: some AbstractSetting) -> [String]? {
        let option = "--" + setting.key.replacingOccurrences(of: "_", with: "-")

        switch setting.wrappedValue {
        case let value as Bool:
            return value ? ["--no-" + option.dropFirst(2)] : [option]
        case is [String]:
            return setting.key == "build_arguments" ? ["--", "lethen-value"] : [option, "lethen-value"]
        case is [FilePath], is FilePath?:
            return [option, "/lethen/value"]
        case is String?:
            return [option, "lethen-value"]
        case let value as OutputFormat:
            return [option, OutputFormat.allCases.first { $0 != value }!.rawValue]
        case let value as ColorOption:
            return [option, ColorOption.allCases.first { $0 != value }!.rawValue]
        default:
            XCTFail("No command-line value for the '\(setting.key)' setting of type \(type(of: setting.wrappedValue))")
            return nil
        }
    }

    /// Converts a property name to its setting key, keeping acronyms together: `noRetainSPI` becomes
    /// `no_retain_spi` and `retainSwiftUIPreviews` becomes `retain_swift_ui_previews`.
    private func snakeCased(_ name: String) -> String {
        let characters = Array(name)
        var result = ""

        for (index, character) in characters.enumerated() {
            if character.isUppercase, index > 0 {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil

                if previous.isLowercase || (previous.isUppercase && next?.isLowercase == true) {
                    result += "_"
                }
            }

            result += character.lowercased()
        }

        return result
    }
}

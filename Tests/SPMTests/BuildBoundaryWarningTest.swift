import Configuration
import Foundation
@testable import ProjectDrivers
import XCTest

final class BuildBoundaryWarningTest: XCTestCase {
    private let packageJSON = """
    {"targets": [
      {"name": "Values", "type": "library", "path": "Sources/Values", "c99name": "Values", "target_dependencies": []},
      {"name": "ValuesTests", "type": "test", "path": "Tests/ValuesTests", "c99name": "ValuesTests", "target_dependencies": ["Values"]},
      {"name": "App", "type": "executable", "path": "Sources/App", "c99name": "App", "target_dependencies": ["Values"]}
    ]}
    """

    /// Decodes as `SPM.Package.load` does, with `convertFromSnakeCase`.
    private func decode(_ json: String) throws -> PackageDescription {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PackageDescription.self, from: Data(json.utf8))
    }

    private func decoded() throws -> PackageDescription {
        try decode(packageJSON)
    }

    func testWarnsWhenExcludedTestsDependOnScannedTargets() throws {
        let configuration = Configuration()
        configuration.excludeTests = true
        let warning = try XCTUnwrap(SPMProjectDriver.buildBoundaryWarning(description: decoded(), configuration: configuration))
        XCTAssertTrue(warning.contains("ValuesTests"), warning)
        XCTAssertTrue(warning.contains("--retain-public-targets Values"), warning)
    }

    func testWarnsWhenExcludedTargetsDependOnScannedTargets() throws {
        let configuration = Configuration()
        configuration.excludeTargets = ["App"]
        let warning = try XCTUnwrap(SPMProjectDriver.buildBoundaryWarning(description: decoded(), configuration: configuration))
        XCTAssertTrue(warning.contains("App"), warning)
        XCTAssertTrue(warning.contains("--retain-public-targets Values"), warning)
    }

    func testNoWarningWhenTargetIsRetainedOrPublicIsRetained() throws {
        let configuration = Configuration()
        configuration.excludeTests = true
        configuration.retainPublicTargets = ["Values"]
        XCTAssertNil(try SPMProjectDriver.buildBoundaryWarning(description: decoded(), configuration: configuration))

        let retainAll = Configuration()
        retainAll.excludeTests = true
        retainAll.retainPublic = true
        XCTAssertNil(try SPMProjectDriver.buildBoundaryWarning(description: decoded(), configuration: retainAll))
    }

    func testNoWarningWhenNothingIsExcluded() throws {
        XCTAssertNil(try SPMProjectDriver.buildBoundaryWarning(description: decoded(), configuration: Configuration()))
    }

    private let pluginToolJSON = """
    {"targets": [
      {"name": "Values", "type": "library", "path": "Sources/Values", "c99name": "Values", "target_dependencies": [], "product_memberships": ["Tool"]},
      {"name": "Tool", "type": "executable", "path": "Sources/Tool", "c99name": "Tool", "target_dependencies": ["Values"], "product_memberships": ["Tool"]},
      {"name": "ToolPlugin", "type": "plugin", "path": "Plugins/ToolPlugin", "c99name": "ToolPlugin", "target_dependencies": ["Tool"]}
    ]}
    """

    func testWarnsWhenAnUnbuiltTargetDependsOnScannedTargets() throws {
        let description = try decode(pluginToolJSON)

        let warning = try XCTUnwrap(SPMProjectDriver.buildBoundaryWarning(description: description, configuration: Configuration(), unbuiltTargets: ["Tool"]))

        XCTAssertTrue(warning.contains("Tool"), warning)
        XCTAssertTrue(warning.contains("not compiled"), warning)
        XCTAssertTrue(warning.contains("--retain-public-targets Values"), warning)
    }

    func testTargetBothExcludedAndUnbuiltIsOnlyExcluded() throws {
        let configuration = Configuration()
        configuration.excludeTargets = ["App"]
        let warning = try XCTUnwrap(SPMProjectDriver.buildBoundaryWarning(description: decoded(), configuration: configuration, unbuiltTargets: ["App"]))
        XCTAssertEqual(warning, "Targets App are excluded from the scan but depend on Values. Public declarations used only from them will be reported; pass --retain-public-targets Values to keep them.")
        XCTAssertFalse(warning.contains("Targets  "), warning)
    }

    func testNoUnbuiltWarningWhenTargetIsRetainedOrPublicIsRetained() throws {
        let description = try decode(pluginToolJSON)
        let retainedTarget = Configuration()
        retainedTarget.retainPublicTargets = ["Values"]
        XCTAssertNil(SPMProjectDriver.buildBoundaryWarning(description: description, configuration: retainedTarget, unbuiltTargets: ["Tool"]))

        let retainAll = Configuration()
        retainAll.retainPublic = true
        XCTAssertNil(SPMProjectDriver.buildBoundaryWarning(description: description, configuration: retainAll, unbuiltTargets: ["Tool"]))
        XCTAssertNil(SPMProjectDriver.buildBoundaryWarning(description: description, configuration: Configuration(), unbuiltTargets: []))
    }

    func testProductMembershipsDecodeWhenPresentAndAbsent() throws {
        let description = try decode(pluginToolJSON)
        XCTAssertEqual(description.targets.first { $0.name == "Tool" }?.productMemberships, ["Tool"])
        XCTAssertNil(description.targets.first { $0.name == "ToolPlugin" }?.productMemberships)
        XCTAssertNil(try decoded().targets.first?.productMemberships)
        XCTAssertEqual(description.targets.first { $0.name == "Tool" }?.targetDependencies, ["Values"], "snake-case keys must survive SPM.load's decoder")
    }
}

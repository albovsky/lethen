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

    private func decoded() throws -> PackageDescription {
        try JSONDecoder().decode(PackageDescription.self, from: Data(packageJSON.utf8))
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
}

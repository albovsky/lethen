import Foundation
@testable import Frontend
import SystemPackage
@testable import TestShared
import XCTest

/// Runs the real scan through the command, reusing the fixture package the other fixture tests build.
final class ScanCommandFixtureTest: FixtureSourceGraphTestCase {
    func testScanReportsFixtureResults() throws {
        let originalDirectory = FilePath.current
        let resultsURL = FileManager.default.temporaryDirectory.appendingPathComponent("lethen-fixture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: resultsURL) }

        let command = try ScanCommand.parse([
            "--project-root", FixturesProjectPath.string,
            "--skip-build",
            "--format", "json",
            "--write-results", resultsURL.path,
            "--disable-update-check",
            "--quiet",
        ])
        _ = try captureOutput(of: STDOUT_FILENO) {
            try command.run()
        }

        XCTAssertEqual(FilePath.current, originalDirectory)
        let data = try Data(contentsOf: resultsURL)
        let results = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let names = Set(results.compactMap { $0["name"] as? String })
        // Reported: an unused free function.
        XCTAssertTrue(names.contains("functionWithSimpleReturnType()"), "\(names.count) results")
        // Retained: a class used as a superclass from another module, and its subclass, which an ignore comment retains.
        XCTAssertFalse(names.contains("FixtureClass129"))
    }
}

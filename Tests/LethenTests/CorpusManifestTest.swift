import Foundation
@testable import TestShared
import XCTest

/// The corpus manifest is data the scripts trust; keep it well-formed.
final class CorpusManifestTest: XCTestCase {
    private struct Entry: Decodable {
        let name: String
        let url: String
        let commit: String
        let kind: String
        let arguments: [String]
    }

    func testManifestEntriesArePinnedAndUnique() throws {
        let path = ProjectRootPath.appending("corpus/projects.json")
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: path.url))

        XCTAssertFalse(entries.isEmpty)
        XCTAssertEqual(Set(entries.map(\.name)).count, entries.count, "names must be unique")
        for entry in entries {
            XCTAssertTrue(entry.commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil, "\(entry.name) must pin a full commit SHA")
            XCTAssertTrue(["spm", "xcode"].contains(entry.kind), "\(entry.name) has unknown kind \(entry.kind)")
            XCTAssertTrue(entry.url.hasPrefix("https://"), "\(entry.name) must use an https URL")
            // corpus/scan.sh reads arguments one per line and skips empty lines.
            XCTAssertFalse(entry.arguments.contains { $0.isEmpty || $0.contains("\n") }, "\(entry.name) has an empty or multi-line argument")
            XCTAssertTrue(ProjectRootPath.appending("corpus/expected/\(entry.name).json").exists, "\(entry.name) has no committed expectation")
        }
    }
}

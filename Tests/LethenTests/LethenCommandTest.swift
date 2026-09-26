import ArgumentParser
import Foundation
@testable import Frontend
import Shared
import XCTest

final class LethenCommandTest: XCTestCase {
    func testParsesEachSubcommand() throws {
        XCTAssertTrue(try LethenCommand.parseAsRoot(["scan"]) is ScanCommand)
        XCTAssertTrue(try LethenCommand.parseAsRoot(["check-update"]) is CheckUpdateCommand)
        XCTAssertTrue(try LethenCommand.parseAsRoot(["clear-cache"]) is ClearCacheCommand)
        XCTAssertTrue(try LethenCommand.parseAsRoot(["version"]) is VersionCommand)
    }

    func testVersionCommandPrintsVersion() throws {
        var command = try LethenCommand.parseAsRoot(["version"])
        let output = try captureOutput(of: STDOUT_FILENO) { try command.run() }
        XCTAssertEqual(output, "\(LethenVersion)\n")
    }

    func testFoundIssuesExitsWithFailure() {
        let error = LethenError.foundIssues(count: 2)
        XCTAssertEqual(LethenCommand.exitCode(for: error), .failure)
        XCTAssertEqual(LethenCommand.message(for: error), "Found 2 issues.")
    }

    func testUnknownSubcommandIsAParseError() {
        XCTAssertThrowsError(try LethenCommand.parseAsRoot(["scna"])) { error in
            XCTAssertNotEqual(LethenCommand.exitCode(for: error), .success)
        }
    }
}

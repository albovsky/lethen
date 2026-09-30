import ArgumentParser
import Foundation
@testable import Frontend
import Shared
import SystemPackage
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

    /// The cache is removed as one path: a space in it does not split it into other paths to remove.
    func testClearCacheRemovesOnlyTheCacheDirectory() throws {
        let root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen-clear-cache-\(UUID().uuidString)").path)
        defer { try? FileManager.default.removeItem(atPath: root.string) }
        let cache = root.appending("Caches/com.github.peripheryapp")
        let spaced = root.appending("Caches Copy")
        let lookalike = root.appending("Caches")
        try FileManager.default.createDirectory(atPath: cache.appending("DerivedData-1").string, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: spaced.string, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: spaced.appending("keep").string, contents: Data())

        try ClearCacheCommand.removeCache(at: cache)
        XCTAssertFalse(cache.exists)
        XCTAssertTrue(lookalike.exists)

        // A cache path with a space names one directory; its lookalike prefix stays.
        let spacedCache = root.appending("Caches Copy/com.github.peripheryapp")
        try FileManager.default.createDirectory(atPath: spacedCache.string, withIntermediateDirectories: true)
        try ClearCacheCommand.removeCache(at: spacedCache)
        XCTAssertFalse(spacedCache.exists)
        XCTAssertTrue(spaced.appending("keep").exists)
        XCTAssertTrue(lookalike.exists)

        // A cache that was never created is already clear.
        XCTAssertNoThrow(try ClearCacheCommand.removeCache(at: root.appending("Missing")))
    }

    func testUnknownSubcommandIsAParseError() {
        XCTAssertThrowsError(try LethenCommand.parseAsRoot(["scna"])) { error in
            XCTAssertNotEqual(LethenCommand.exitCode(for: error), .success)
        }
    }
}

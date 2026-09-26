import ArgumentParser
import Foundation
@testable import Frontend
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
        let output = try captureStandardOutput { try command.run() }
        XCTAssertEqual(output, "\(LethenVersion)\n")
    }

    func testUnknownSubcommandIsAParseError() {
        XCTAssertThrowsError(try LethenCommand.parseAsRoot(["scna"])) { error in
            XCTAssertNotEqual(LethenCommand.exitCode(for: error), .success)
        }
    }
}

/// Runs `body` with standard output redirected to a pipe and returns what it printed.
func captureStandardOutput(_ body: () throws -> Void) throws -> String {
    fflush(stdout)
    let pipe = Pipe()
    let savedDescriptor = dup(STDOUT_FILENO)
    dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

    func restore() {
        fflush(stdout)
        dup2(savedDescriptor, STDOUT_FILENO)
        close(savedDescriptor)
    }

    do {
        try body()
    } catch {
        restore()
        throw error
    }

    restore()
    try pipe.fileHandleForWriting.close()
    return try XCTUnwrap(String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
}

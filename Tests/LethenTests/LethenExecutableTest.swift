import Foundation
@testable import Frontend
import XCTest

/// Importing the library never runs `main.swift`, so these launch the built executable.
final class LethenExecutableTest: XCTestCase {
    func testVersionCommand() throws {
        let (status, output) = try launch(["version"])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(output, "\(LethenVersion)\n")
    }

    func testScanHelp() throws {
        let (status, output) = try launch(["scan", "--help"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.contains("USAGE: lethen scan"), output)
    }

    func testUnknownCommandFails() throws {
        let (status, _) = try launch(["scna"])
        XCTAssertNotEqual(status, 0)
    }

    // MARK: - Private

    /// The executable sits next to the test products in the build directory.
    private func executableURL() throws -> URL {
        #if os(macOS)
            let productsURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        #else
            let productsURL = Bundle.main.bundleURL
        #endif
        let url = productsURL.appendingPathComponent("lethen")

        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("The lethen executable is not built at \(url.path); run 'swift build' first.")
        }

        return url
    }

    private func launch(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try (process.terminationStatus, XCTUnwrap(String(bytes: data, encoding: .utf8)))
    }
}

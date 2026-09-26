import Shared
import XCTest

final class SwiftVersionTest: XCTestCase {
    private struct StubShell: Shell {
        let output: String?

        func exec(_ args: [String]) throws -> String {
            guard let output else {
                throw LethenError.shellCommandFailed(cmd: args, status: 127, output: "swift: command not found")
            }

            return output
        }

        func execStatus(_: [String]) throws -> Int32 {
            0
        }
    }

    func testParsesVersionFromShellOutput() throws {
        let version = try SwiftVersion(shell: StubShell(output: "Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)\nTarget: arm64-apple-macosx27.0.0"))
        XCTAssertEqual(version.version, "6.4")
        XCTAssertNoThrow(try version.validateVersion())
    }

    func testThrowsWhenTheShellCommandFails() {
        XCTAssertThrowsError(try SwiftVersion(shell: StubShell(output: nil))) { error in
            guard let error = error as? LethenError, case .shellCommandFailed = error else {
                return XCTFail("Expected the shell error, got: \(error)")
            }
        }
    }

    func testThrowsWhenTheOutputIsUnparseable() {
        XCTAssertThrowsError(try SwiftVersion(shell: StubShell(output: "not a swift toolchain"))) { error in
            guard let error = error as? LethenError, case .swiftVersionParseError = error else {
                return XCTFail("Expected a parse error, got: \(error)")
            }
        }
    }

    func testRejectsVersionsBelowTheMinimum() throws {
        let version = try SwiftVersion(shell: StubShell(output: "Apple Swift version 5.9 (swiftlang-5.9.0.128.108 clang-1500.0.40.1)\nTarget: arm64-apple-macosx14.0"))
        XCTAssertThrowsError(try version.validateVersion()) { error in
            guard let error = error as? LethenError, case .swiftVersionUnsupportedError = error else {
                return XCTFail("Expected an unsupported version error, got: \(error)")
            }
        }
    }
}

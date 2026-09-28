import Foundation
@testable import Frontend
import Shared
import SystemPackage
@testable import TestShared
import XCTest

/// Runs `lethen explain` through the command on the fixture package the other fixture tests build.
final class ExplainCommandTest: FixtureSourceGraphTestCase {
    func testReportedDeclarationHasNoReferences() throws {
        let output = try explain("functionWithSimpleReturnType")

        XCTAssertTrue(output.contains("function functionWithSimpleReturnType()"), output)
        XCTAssertTrue(output.contains("Reported as unused."), output)
        XCTAssertTrue(output.contains("No references to its USRs were found"), output)
    }

    /// XCTestRetainer retains the test class, and the class references its test methods.
    func testRetainedDeclarationNamesTheRetainer() throws {
        let output = try explain("FixtureClass34.testSomething")

        XCTAssertTrue(output.contains("class FixtureClass34 at"), output)
        XCTAssertTrue(output.contains("retained by XCTestRetainer"), output)
        XCTAssertTrue(output.contains("references function testSomething()"), output)
        // The qualified name selects the method of FixtureClass34 only, not the subclass's methods.
        let headings = output.split(separator: "\n").filter { $0.hasPrefix("function ") }
        XCTAssertEqual(headings.count, 1, output)
    }

    func testIgnoredDeclarationNamesTheComment() throws {
        let output = try explain("FixtureClass129Retainer")

        XCTAssertTrue(output.contains("Not reported: ignored by a `// periphery:ignore` comment"), output)
    }

    /// The subclass is only referenced from a method of a class an ignore comment retains.
    func testUsedDeclarationShowsTheChainFromARetainedDeclaration() throws {
        let output = try explain("CrossModuleRetentionFixtures.FixtureClass129")

        XCTAssertTrue(output.contains("Used, through this chain of references:"), output)
        XCTAssertTrue(output.contains("retained by a `// periphery:ignore` comment"), output)
        XCTAssertTrue(output.contains("references function retain()"), output)
        XCTAssertTrue(output.contains("references class FixtureClass129"), output)
    }

    func testReportedDeclarationStatesItsConfidence() throws {
        // FixtureClass223 is public; with --retain-public its unused methods are reported, not the class.
        let output = try explain("FixtureClass223.namedInLiteral", "--retain-public")

        XCTAssertTrue(output.contains("Confidence: likely, because its name appears in a string literal."), output)

        let certain = try explain("FixtureClass223.notNamedAnywhere", "--retain-public")
        XCTAssertTrue(certain.contains("Confidence: certain."), certain)
    }

    func testUnknownNameIsAUsageError() {
        XCTAssertThrowsError(try explain("noSuchDeclarationAnywhere")) { error in
            guard case let LethenError.usageError(message) = error else {
                return XCTFail("Expected a usage error, got \(error)")
            }

            XCTAssertTrue(message.contains("noSuchDeclarationAnywhere"), message)
        }
    }

    // MARK: - Private

    private func explain(_ query: String, _ arguments: String...) throws -> String {
        let command = try ExplainCommand.parse([
            query,
            "--project-root", FixturesProjectPath.string,
            "--skip-build",
            "--disable-update-check",
            "--quiet",
        ] + arguments)
        return try captureOutput(of: STDOUT_FILENO) {
            try command.run()
        }
    }
}

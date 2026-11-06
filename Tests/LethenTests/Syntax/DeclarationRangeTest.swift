import Foundation
import Logger
import Shared
@testable import SourceGraph
@testable import SyntaxAnalysis
@testable import TestShared
import XCTest

/// The indexer attributes a reference the index leaves without a containing declaration to the innermost declaration
/// whose recorded range contains it, so the ranges must span a declaration from its first attribute to its last token.
final class DeclarationRangeTest: XCTestCase {
    private var ranges: [Location: ClosedRange<Location>]!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let shell = ShellImpl(logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let swiftVersion = try SwiftVersion(shell: shell)
        let multiplexingVisitor = try MultiplexingSyntaxVisitor(file: fixturePath, swiftVersion: swiftVersion)
        let visitor = multiplexingVisitor.add(DeclarationSyntaxVisitor.self)
        multiplexingVisitor.visit()
        ranges = visitor.rangesByLocation
    }

    override func tearDown() {
        ranges = nil
        super.tearDown()
    }

    /// The range starts at the attribute, not at the documentation comment above it, and ends at the closing brace.
    func testTypeSpansAttributesToClosingBrace() {
        XCTAssertEqual(ranges[location(3, 15)], location(2, 1) ... location(16, 2))
    }

    func testFunctionSpansAttributesToClosingBrace() {
        XCTAssertEqual(ranges[location(5, 10)], location(4, 5) ... location(7, 6))
        XCTAssertEqual(ranges[location(18, 6)], location(18, 1) ... location(18, 23))
    }

    func testPropertySpansDeclarationToLastToken() {
        XCTAssertEqual(ranges[location(9, 9)], location(9, 5) ... location(9, 24))
        XCTAssertEqual(ranges[location(10, 9)], location(10, 5) ... location(12, 6))
    }

    func testNestedDeclarationLiesWithinItsContainer() throws {
        let nested = try XCTUnwrap(ranges[location(13, 12)])
        XCTAssertEqual(nested, location(13, 5) ... location(15, 6))
        XCTAssertEqual(ranges[location(14, 13)], location(14, 9) ... location(14, 22))

        let container = try XCTUnwrap(ranges[location(3, 15)])
        XCTAssertTrue(container.contains(nested.lowerBound))
        XCTAssertTrue(container.contains(nested.upperBound))
    }

    /// With several bindings in one declaration each has its own range, so a reference in the second is not the first's.
    func testBindingsOfOneDeclarationHaveSeparateRanges() {
        XCTAssertEqual(ranges[location(19, 5)], location(19, 5) ... location(19, 15))
        XCTAssertEqual(ranges[location(19, 16)], location(19, 16) ... location(19, 26))
    }

    // MARK: - Private

    private var fixturePath: SourceFile {
        let path = FixturesProjectPath.appending("Sources/DeclarationVisitorFixtures/RangeFixture.swift")
        return SourceFile(path: path, modules: ["DeclarationVisitorFixtures"])
    }

    private func location(_ line: Int, _ column: Int) -> Location {
        Location(file: fixturePath, line: line, column: column)
    }
}

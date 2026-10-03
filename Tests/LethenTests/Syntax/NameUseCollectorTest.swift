import Foundation
import SwiftParser
import SwiftSyntax
@testable import SyntaxAnalysis
import SystemPackage
import XCTest

final class NameUseCollectorTest: XCTestCase {
    private func collect(_ source: String) -> NameUseCollector {
        NameUseCollector(Syntax(Parser.parse(source: source)))
    }

    func testSeparatesTheThreeTiers() {
        let collector = collect("""
        func f(value: E) {
            let local = 1
            _ = local
            _ = Plain.self
            call()
            _ = object.member
            if case .matchedOnly = value {}
        }
        """)
        XCTAssertEqual(collector.uses["local"], false, "A bare identifier use is not a member use")
        XCTAssertEqual(collector.uses["Plain"], false)
        XCTAssertEqual(collector.uses["call"], true)
        XCTAssertEqual(collector.uses["member"], true)
        XCTAssertEqual(collector.constructionUses, ["call", "member", "self"], "A pattern does not construct an enum case")
        XCTAssertEqual(collector.uses["matchedOnly"], true)
        XCTAssertTrue(collector.hasIndexableSyntax)
    }

    func testDeclaredNamesAndImportsAreNotUses() {
        let collector = collect("import Foundation\nlet declared = 1\n")
        XCTAssertNil(collector.uses["declared"])
        XCTAssertNil(collector.uses["Foundation"])
    }

    func testReadsUsesOfAFileWithTheirLines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Uses.swift")
        try "func f() {\n    first()\n    second()\n}\n".write(to: file, atomically: true, encoding: .utf8)

        let uses = try NameUseCollector.uses(inFileAt: FilePath(file.path))
        XCTAssertEqual(uses.filter { $0.name == "first" }.map(\.line), [2])
        XCTAssertEqual(uses.filter { $0.name == "second" }.map(\.line), [3])
        XCTAssertThrowsError(try NameUseCollector.uses(inFileAt: FilePath(directory.appendingPathComponent("Missing.swift").path)))
    }
}

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

    /// `Widget(...)` calls an initializer, `store[key]` a subscript; the index records both under those names.
    func testConstructorCallsAndSubscriptsAreMemberUses() {
        let collector = collect("""
        let widget = Widget(size: 1)
        let value = store[key]
        let other = makeWidget()
        _ = Store.shared[0]
        """)
        XCTAssertEqual(collector.uses["init"], true)
        XCTAssertNil(collector.uses["Widget.init"], "A qualified spelling is for the file reader, not the index names")
        XCTAssertEqual(collector.uses["subscript"], true)
        XCTAssertTrue(collector.constructionUses.isSuperset(of: ["init", "subscript", "Widget"]))
        XCTAssertEqual(collector.uses["makeWidget"], true, "A call to a function records only the function")
    }

    /// A member spelled through its type is also reported as `Type.member`, so a match can be placed at a use
    /// of this type's member rather than at any type's.
    func testQualifiedMemberUsesReachTheFileReader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Qualified.swift")
        try "let a = Widget(size: 1)\nlet b = Store.shared\nlet c = store.shared\n".write(to: file, atomically: true, encoding: .utf8)

        let uses = try NameUseCollector.uses(inFileAt: FilePath(file.path)).uses
        XCTAssertEqual(uses.filter { $0.name == "Widget.init" }.map(\.line), [1])
        XCTAssertEqual(uses.filter { $0.name == "Store.shared" }.map(\.line), [2])
        XCTAssertEqual(uses.filter { $0.name == "shared" }.map(\.line), [2, 3], "The bare name is recorded for both spellings")
    }

    func testTestableImportsAreRecorded() {
        let collector = collect("import Foundation\n@testable import App\n@testable import Core\nlet x = 1\n")
        XCTAssertEqual(collector.testableModules, ["App", "Core"])
        XCTAssertNil(collector.uses["App"], "An import path is not a use")
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

        let uses = try NameUseCollector.uses(inFileAt: FilePath(file.path)).uses
        XCTAssertEqual(uses.filter { $0.name == "first" }.map(\.line), [2])
        XCTAssertEqual(uses.filter { $0.name == "second" }.map(\.line), [3])
        XCTAssertThrowsError(try NameUseCollector.uses(inFileAt: FilePath(directory.appendingPathComponent("Missing.swift").path)))
    }
}

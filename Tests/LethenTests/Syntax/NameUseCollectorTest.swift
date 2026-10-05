import Foundation
import SourceGraph
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

    /// `Widget(...)` calls an initializer, `store[key]` a subscript; those names reach the file reader only,
    /// since in a skipped `#if` clause they would match every initializer or subscript of the module.
    func testConstructorCallsAndSubscriptsAreUsesForTheFileReaderOnly() {
        var seen: [String] = []
        _ = NameUseCollector(Syntax(Parser.parse(source: "let widget = Widget(size: 1)\nlet value = store[key]\nlet other = makeWidget()\nlet qualified = Framework.Button(title: \"x\")\nlet generic = Framework.Box<Int>()\n"))) { seen.append($0.name) }
        XCTAssertTrue(seen.contains("init"))
        XCTAssertTrue(seen.contains("Widget.init"))
        XCTAssertTrue(seen.contains("Button.init"), "A module-qualified construction is a constructor call too")
        XCTAssertTrue(seen.contains("Box.init"), "So is a generic one")

        var macros: [String] = []
        _ = NameUseCollector(Syntax(Parser.parse(source: "let w = #makeWidget()\n#warning(\"x\")\n"))) { macros.append($0.name) }
        XCTAssertTrue(macros.contains("makeWidget"), "A freestanding macro is named by its own token")
        XCTAssertTrue(seen.contains("subscript"))
        XCTAssertFalse(seen.contains("makeWidget.init"))

        let collector = collect("let widget = Widget(size: 1)\nlet value = store[key]\nlet other = makeWidget()\n")
        XCTAssertNil(collector.uses["init"])
        XCTAssertNil(collector.uses["subscript"])
        XCTAssertEqual(collector.uses["Widget"], true)
        XCTAssertEqual(collector.uses["makeWidget"], true, "A call to a function records only the function")
    }

    func testConstructorCallsSpellInitThroughTheTypeBeside() {
        typealias Spelling = NameSites.Spelling
        let collector = collect("""
        func f() {
            _ = Widget(size: 1)
            _ = Widget { }
            _ = Framework.Gadget<Int>(name: n)
            _ = T(size: 1)
            _ = Self()
            _ = Widget.make(size: 1)
        }
        func g<T>() {}
        """)
        XCTAssertEqual(collector.spellings["init"], [
            Spelling(labels: ["size"], receiver: "Widget", isMember: true),
            Spelling(labels: [], hasTrailingClosure: true, receiver: "Widget", isMember: true),
            Spelling(labels: ["name"], receiver: "Gadget", isMember: true),
            Spelling(labels: ["size"], isMember: true),
            Spelling(labels: [], isMember: true),
        ])
        XCTAssertNil(collector.uses["init"], "`init` is not named for every type")
        XCTAssertNil(collector.constructionUses.first { $0 == "init" })
    }

    /// A clause is collected without the declaration around it, whose generic parameters still stand for any type.
    func testGenericParametersOfTheEnclosingDeclarationAreNotReceivers() throws {
        typealias Spelling = NameSites.Spelling
        let tree = Parser.parse(source: "func f<T: P>() {\n #if os(Windows)\n _ = T(size: 1)\n _ = Widget(size: 1)\n #endif\n}")
        let clause = try XCTUnwrap(findIfConfig(Syntax(tree)))
        let elements = try XCTUnwrap(clause.clauses.first?.elements)
        let collector = NameUseCollector(Syntax(elements))
        XCTAssertEqual(collector.spellings["init"], [
            Spelling(labels: ["size"], isMember: true),
            Spelling(labels: ["size"], receiver: "Widget", isMember: true),
        ])
    }

    private func findIfConfig(_ node: Syntax) -> IfConfigDeclSyntax? {
        if let found = node.as(IfConfigDeclSyntax.self) { return found }
        for child in node.children(viewMode: .sourceAccurate) {
            if let found = findIfConfig(child) { return found }
        }
        return nil
    }

    func testEnumCaseUsesInAPatternAreMarked() {
        typealias Spelling = NameSites.Spelling
        let collector = collect("func f(a: A) {\n _ = A.ready\n _ = .go\n switch a { case .go: break; case A.ready: break }\n}")
        XCTAssertEqual(collector.spellings["ready"], [
            Spelling(receiver: "A", isMember: true),
            Spelling(receiver: "A", isMember: true, isPattern: true),
        ])
        XCTAssertEqual(collector.spellings["go"], [Spelling(isMember: true), Spelling(isMember: true, isPattern: true)])
    }

    /// An `override` names the base member, so its name is a member use; the same declaration without `override`
    /// is a new member and uses nothing.
    func testOverridesUseTheNamesTheyOverride() {
        let collector = collect("""
        class Derived: Base {
            override func run() {}
            override var title: String { "t" }
            override init() { super.init() }
            override subscript(index: Int) -> Int { 0 }
        }
        """)
        XCTAssertEqual(collector.uses["run"], true)
        XCTAssertEqual(collector.uses["title"], true)
        XCTAssertEqual(collector.constructionUses.isSuperset(of: ["run", "title"]), true)
        XCTAssertEqual(collector.uses["Base"], false)

        var seen: [String] = []
        _ = NameUseCollector(Syntax(Parser.parse(source: "class Derived: Base { override init() {}\n override subscript(i: Int) -> Int { 0 } }"))) { seen.append($0.name) }
        XCTAssertTrue(seen.contains("subscript"))
        XCTAssertTrue(seen.contains("init"))

        let control = collect("class Derived: Base { func run() {}\n var title: String { \"t\" } }")
        XCTAssertNil(control.uses["run"], "A declaration without override introduces its own member")
        XCTAssertNil(control.uses["title"])
    }

    /// `Handler()()` and `handler(1)` can run a `callAsFunction` that no call spells; a type construction cannot.
    func testCallableValueCallsReachTheFileReaderAsCallAsFunction() {
        func names(_ source: String) -> [String] {
            var seen: [String] = []
            _ = NameUseCollector(Syntax(Parser.parse(source: source))) { seen.append($0.name) }
            return seen
        }
        XCTAssertTrue(names("let a = Handler()()").contains("callAsFunction"), "The callee is a call")
        XCTAssertTrue(names("let a = handler(1)").contains("callAsFunction"), "The callee is a value")
        XCTAssertTrue(names("let a = object.handler(1)").contains("callAsFunction"))
        XCTAssertTrue(names("let a = (make())(1)").contains("callAsFunction"))
        XCTAssertTrue(names("func use(_ _handler: Handler) { _handler() }").contains("callAsFunction"), "Leading underscores do not make a type name")
        XCTAssertTrue(names("let invoke: (Handler) -> Void = { $0() }").contains("callAsFunction"), "A shorthand argument is a value")
        XCTAssertFalse(names("let a = _Handler(size: 1)").contains("callAsFunction"))
        XCTAssertFalse(names("let a = Handler(size: 1)").contains("callAsFunction"), "A construction is not a callable value")
        XCTAssertFalse(names("let a = Framework.Handler(size: 1)").contains("callAsFunction"))

        XCTAssertNil(collect("let a = Handler()()").uses["callAsFunction"], "It reaches the file reader only")
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

    func testRecordsLabelsTrailingClosureAndReceiverOfEachSpelling() {
        let collector = collect("""
        func f() {
            show(title: t, 1)
            run { }
            animate(duration: 1) { } completion: { }
            let g = show
            let h = show(title:)
            Store.shared.load()
            _ = Store.shared
            _ = Store.init(data: d)
            _ = self.shared
            _ = Self.shared
            _ = T.shared
        }
        func make<T>() {}
        """)
        typealias Spelling = NameSites.Spelling
        XCTAssertEqual(collector.spellings["show"], [
            Spelling(labels: ["title", "_"], isMember: true),
            Spelling(labels: nil),
            Spelling(labels: ["title"]),
        ])
        XCTAssertEqual(collector.spellings["run"], [Spelling(labels: [], hasTrailingClosure: true, isMember: true)])
        XCTAssertEqual(
            collector.spellings["animate"],
            [Spelling(labels: ["duration", "completion"], hasTrailingClosure: true, isMember: true)]
        )
        XCTAssertEqual(collector.spellings["load"], [Spelling(labels: [], isMember: true)], "`Store.shared` is not the receiver of `load`")
        XCTAssertEqual(collector.spellings["init"], [Spelling(labels: ["data"], receiver: "Store", isMember: true)])
        XCTAssertEqual(
            collector.spellings["shared"],
            [Spelling(receiver: "Store", isMember: true), Spelling(isMember: true)],
            "`self.shared` and `Self.shared` name no type"
        )
    }

    func testAGenericParameterIsNotAReceiver() {
        typealias Spelling = NameSites.Spelling
        let collector = collect("func make<T: Base>(_: T.Type) { _ = T.shared }\nfunc other() { _ = U.shared }")
        XCTAssertEqual(
            collector.spellings["shared"],
            [Spelling(isMember: true), Spelling(receiver: "U", isMember: true)]
        )
    }
}

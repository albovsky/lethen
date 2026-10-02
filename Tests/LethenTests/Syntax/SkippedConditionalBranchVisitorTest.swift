import SourceGraph
import SwiftParser
import SwiftSyntax
@testable import SyntaxAnalysis
import SystemPackage
import XCTest

final class SkippedConditionalBranchVisitorTest: XCTestCase {
    private let source = """
    #if os(Windows)
    import WinSDK
    #endif
    func f() {
        #if os(Linux)
        linuxCall()
        #elseif os(Windows)
        windowsCall(argument)
        #else
        otherCall()
        #endif
        #if os(Windows)
        otherCall()
        #endif
        #if os(macOS)
        // nothing but a comment
        #endif
    }
    """

    func testCollectsNamesOfClausesWithoutEvidenceWithTheirSites() {
        // Evidence on line 6 marks the `os(Linux)` clause as the one that compiled.
        let names = collect(source, evidenceLines: [6])
        XCTAssertEqual(names, [
            "windowsCall": "#elseif os(Windows) at Test.swift:7",
            "argument": "#elseif os(Windows) at Test.swift:7",
            "otherCall": "#else at Test.swift:9",
        ])
    }

    func testImportOnlyAndCommentOnlyClausesAreNotEvidenceOfAnything() {
        let names = collect(source, evidenceLines: [6, 8, 10])
        XCTAssertEqual(names, ["otherCall": "#if os(Windows) at Test.swift:12"])
    }

    /// A file built into two modules compiles different clauses in each, so evidence is per module: the
    /// indexer runs the visitor once per module's evidence, and each run sees only its own taken clauses.
    func testEvidenceOfOneModuleDoesNotMakeAClauseTakenForAnother() {
        // Module A compiled the `os(Linux)` clause (line 6), module B the `os(Windows)` one (line 8).
        let moduleA = collect(source, evidenceLines: [6, 10])
        let moduleB = collect(source, evidenceLines: [8, 10])
        XCTAssertNotNil(moduleA["windowsCall"])
        XCTAssertNil(moduleA["linuxCall"])
        XCTAssertNotNil(moduleB["linuxCall"])
        XCTAssertNil(moduleB["windowsCall"])
        // The union, which a shared evidence set would give, hides both.
        let union = collect(source, evidenceLines: [6, 8, 10])
        XCTAssertNil(union["windowsCall"])
        XCTAssertNil(union["linuxCall"])
    }

    func testNamesAreNotCollectedWhenEveryClauseIsTaken() {
        XCTAssertEqual(collect(source, evidenceLines: [6, 8, 10, 13]), [:])
    }

    func testForCaseAndBareLocalsAreNotMemberUses() {
        let source = """
        func f(values: [E]) {
            #if os(Windows)
            for case .windowsOnly in values {}
            switch limit { case Limits.windowsValue: break; default: break }
            let idle = values
            consume(idle)
            #endif
        }
        """
        let visitor = run(source, evidenceLines: [])
        // A pattern matches an enum case without constructing it, but it reads a static property.
        XCTAssertNotNil(visitor.memberNames["windowsOnly"])
        XCTAssertNil(visitor.constructionNames["windowsOnly"])
        XCTAssertNotNil(visitor.memberNames["windowsValue"])
        XCTAssertNil(visitor.constructionNames["windowsValue"])
        XCTAssertNotNil(visitor.constructionNames["consume"])
        XCTAssertNotNil(visitor.names["idle"])
        XCTAssertNil(visitor.memberNames["idle"])
    }

    /// Every form that names a declaration without a plain reference, call or member access.
    func testCollectsNamesFromTypeKeyPathMacroAndInterpolationForms() {
        let forms: [(String, String, Bool)] = [
            ("_ = nil as CastType?", "CastType", false),
            ("_ = x is IsType", "IsType", false),
            ("_ = x as! ForcedType", "ForcedType", false),
            ("_ = Box<GenericArg>()", "GenericArg", false),
            ("_ = Meta.self", "Meta", false),
            ("let t: MetaType.Type = z", "MetaType", false),
            ("_ = \\Model.keyPathProperty", "keyPathProperty", true),
            ("_ = \\Model.items[0].optionalPart?.deepProperty", "deepProperty", true),
            ("_ = #selector(Target.action)", "action", true),
            ("_ = #keyPath(Target.path)", "path", true),
            ("_ = \"\\(interpolated)\"", "interpolated", false),
            ("let c = { (p: ClosureParamType) in }", "ClosureParamType", false),
            ("func g<T>(_ v: T) where T: WhereProtocol {}", "WhereProtocol", false),
            ("struct S: InheritedProtocol {}", "InheritedProtocol", false),
            ("@WrapperAttribute var w = 0", "WrapperAttribute", false),
            ("_ = x[subscriptIndex]", "subscriptIndex", false),
            ("extension ExtendedType {}", "ExtendedType", false),
        ]
        for (code, name, isMember) in forms {
            let visitor = run("func f() {\n#if os(Windows)\n\(code)\n#endif\n}", evidenceLines: [])
            XCTAssertNotNil(visitor.names[name], "\(code) should name \(name)")
            XCTAssertEqual(visitor.memberNames[name] != nil, isMember, "\(code) member use of \(name)")
        }
    }

    func testCollectsOperatorsAsBareUses() {
        let source = """
        func f(a: Int) {
            #if os(Windows)
            _ = a <+> 1
            _ = ^^^a
            _ = a+++
            _ = reduce(<*>)
            #endif
        }
        """
        let visitor = run(source, evidenceLines: [])
        XCTAssertEqual(Set(["<+>", "^^^", "+++", "<*>"]).subtracting(visitor.names.keys), [])
        XCTAssertTrue(visitor.memberNames.keys.allSatisfy { !["<+>", "^^^", "+++"].contains($0) })
    }

    func testCollectsUsesButNotDeclarationsLabelsOrPatterns() {
        let source = """
        func f(value: E) {
            #if os(Windows)
            func declared(label parameter: Int) {}
            declared(label: 1)
            _ = Module.qualified
            obj.member()
            bare()
            let local = bareReference
            switch value { case .matchedOnly: break }
            if case .alsoMatched = value {}
            #endif
        }
        """
        let visitor = run(source, evidenceLines: [])
        XCTAssertEqual(Set(visitor.names.keys), ["declared", "Int", "Module", "qualified", "obj", "member", "bare", "bareReference", "value", "matchedOnly", "alsoMatched"])
        // `declared(label:)` and `bare()` are calls, `obj.member` and `Module.qualified` member accesses, and
        // the matched cases are member accesses inside patterns.
        XCTAssertEqual(Set(visitor.memberNames.keys), ["declared", "qualified", "member", "bare", "matchedOnly", "alsoMatched"])
        // Patterns match enum cases without constructing them.
        XCTAssertEqual(Set(visitor.constructionNames.keys), ["declared", "qualified", "member", "bare"])
    }

    private func collect(_ source: String, evidenceLines: [Int]) -> [String: String] {
        run(source, evidenceLines: evidenceLines).names
    }

    private func run(_ source: String, evidenceLines: [Int]) -> SkippedConditionalBranchVisitor {
        let file = SourceFile(path: FilePath("/tmp/Test.swift"), modules: ["Test"])
        let syntax = Parser.parse(source: source)
        let locationBuilder = SourceLocationBuilder(
            file: file, locationConverter: SourceLocationConverter(fileName: "Test.swift", tree: syntax)
        )
        let evidence = Set(evidenceLines.map { Location(file: file, line: $0, column: 5) })
        let visitor = SkippedConditionalBranchVisitor(locationBuilder: locationBuilder, evidence: evidence)
        visitor.walk(syntax)
        return visitor
    }
}

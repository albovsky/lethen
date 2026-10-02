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

    func testNamesAreNotCollectedWhenEveryClauseIsTaken() {
        XCTAssertEqual(collect(source, evidenceLines: [6, 8, 10, 13]), [:])
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
        XCTAssertEqual(Set(visitor.names.keys), ["declared", "Int", "Module", "qualified", "obj", "member", "bare", "bareReference", "value"])
        // `declared(label:)` and `bare()` are calls, `obj.member` and `Module.qualified` member accesses.
        XCTAssertEqual(Set(visitor.memberNames.keys), ["declared", "qualified", "member", "bare"])
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

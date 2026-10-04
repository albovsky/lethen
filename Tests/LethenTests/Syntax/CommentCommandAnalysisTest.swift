import Configuration
@testable import Indexer
import SourceGraph
@testable import SyntaxAnalysis
import SystemPackage
import XCTest

final class CommentCommandAnalysisTest: XCTestCase {
    private let sourceFile = SourceFile(path: FilePath("/t/T.swift"), modules: ["T"])

    private func declaration(_ name: String, line: Int, kind: Declaration.Kind = .functionFree, column: Int = 6) -> Declaration {
        Declaration(name: name, kind: kind, usrs: ["s:\(name)"], location: Location(file: sourceFile, line: line, column: column))
    }

    func testIgnoreAllRetainsParametersAddedBeforeIt() throws {
        let source = "func f(a: Int) {}\nfunc g() {}\n"
        let f = declaration("f(a:)", line: 1)
        let g = declaration("g()", line: 2)
        let (file, _, graph, _) = makeIndexedFile(source: source, declarations: [f, g], fileCommands: [.ignoreAll])
        try UnusedParameterAnalysis(configuration: Configuration()).apply(to: file)
        let parameter = try XCTUnwrap(f.unusedParameters.first)
        XCTAssertFalse(graph.isRetained(parameter), "The control: the parameter is not retained before the command applies")

        try CommentCommandAnalysis(configuration: Configuration()).apply(to: file)

        XCTAssertTrue(graph.isRetained(f))
        XCTAssertTrue(graph.isRetained(g))
        XCTAssertTrue(graph.isRetained(parameter))
        XCTAssertEqual(graph.commandIgnoredDeclarations[parameter], .file)
        XCTAssertEqual(graph.commandIgnoredDeclarations[g], .file)
    }

    func testIgnoreRetainsTheDeclarationItsParametersAndItsChildren() throws {
        let source = "struct S {\n    func m(a: Int) {}\n}\nfunc other() {}\n"
        let s = declaration("S", line: 1, kind: .struct)
        let m = declaration("m(a:)", line: 2, column: 10)
        m.parent = s
        s.declarations = [m]
        s.commentCommands = [.ignore]
        let other = declaration("other()", line: 4)
        let (file, _, graph, _) = makeIndexedFile(source: source, declarations: [s, m, other])
        try UnusedParameterAnalysis(configuration: Configuration()).apply(to: file)
        try CommentCommandAnalysis(configuration: Configuration()).apply(to: file)

        XCTAssertTrue(graph.isRetained(s))
        XCTAssertTrue(graph.isRetained(m))
        XCTAssertEqual(graph.commandIgnoredDeclarations[m], .declaration)
        XCTAssertTrue(try graph.isRetained(XCTUnwrap(m.unusedParameters.first)))
        XCTAssertFalse(graph.isRetained(other), "The control: a declaration without the command is not retained")
        XCTAssertNil(graph.commandIgnoredDeclarations[other])
    }
}

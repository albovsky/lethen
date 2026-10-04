import Configuration
@testable import Indexer
import SourceGraph
import SwiftSyntax
@testable import SyntaxAnalysis
import SystemPackage
import XCTest

final class UnusedParameterAnalysisTest: XCTestCase {
    private let source = "func f(a: Int, b: Int) { _ = b }\n"

    private func function(commands: Set<CommentCommand> = [], isObjcAccessible: Bool = false) -> Declaration {
        let sourceFile = SourceFile(path: FilePath("/t/T.swift"), modules: ["T"])
        let decl = Declaration(name: "f(a:b:)", kind: .functionFree, usrs: [isObjcAccessible ? "c:f" : "s:f"], location: Location(file: sourceFile, line: 1, column: 6))
        decl.commentCommands = commands
        decl.isObjcAccessible = isObjcAccessible
        return decl
    }

    private func analyze(
        _ decl: Declaration,
        retainsAllDeclarations: Bool = false,
        retainObjcAccessible: Bool = false
    ) throws -> SourceGraph {
        var configuration = Configuration()
        configuration.retainObjcAccessible = retainObjcAccessible
        let (file, _, graph, _) = makeIndexedFile(
            source: source, declarations: [decl], retainsAllDeclarations: retainsAllDeclarations, configuration: configuration
        )
        try UnusedParameterAnalysis(configuration: configuration).apply(to: file)
        return graph
    }

    func testUnusedParameterIsAddedToTheFunctionAndTheGraph() throws {
        let decl = function()
        let graph = try analyze(decl)

        XCTAssertEqual(decl.unusedParameters.map(\.name), ["a"], "b is used, so only a is added")
        let parameter = try XCTUnwrap(decl.unusedParameters.first)
        XCTAssertTrue(graph.allDeclarations.contains(parameter))
        XCTAssertFalse(graph.isRetained(parameter))
    }

    func testParametersOfRetainedFileAreRetained() throws {
        let decl = function()
        let graph = try analyze(decl, retainsAllDeclarations: true)

        let parameter = try XCTUnwrap(decl.unusedParameters.first)
        XCTAssertTrue(graph.isRetained(parameter))
    }

    func testObjcAccessibleParameterIsRetainedOnlyWhenConfigured() throws {
        let retained = function(isObjcAccessible: true)
        let retainedGraph = try analyze(retained, retainObjcAccessible: true)
        XCTAssertTrue(try retainedGraph.isRetained(XCTUnwrap(retained.unusedParameters.first)))

        let control = function(isObjcAccessible: true)
        let controlGraph = try analyze(control)
        XCTAssertFalse(try controlGraph.isRetained(XCTUnwrap(control.unusedParameters.first)), "The control: not retained without the option")
    }

    func testIgnoredParameterIsRetainedAndCommandIgnored() throws {
        let decl = function(commands: [.ignoreParameters(["a"])])
        let graph = try analyze(decl)

        let parameter = try XCTUnwrap(decl.unusedParameters.first)
        XCTAssertTrue(graph.isRetained(parameter))
        XCTAssertNotNil(graph.commandIgnoredDeclarations[parameter])
        XCTAssertTrue(graph.functionsWithIgnoredParameters.contains(decl))
    }

    func testUnignoredParameterIsReported() throws {
        let decl = function(commands: [.ignoreParameters(["b"])])
        let graph = try analyze(decl)

        let parameter = try XCTUnwrap(decl.unusedParameters.first)
        XCTAssertFalse(graph.isRetained(parameter), "The control: ignoring another parameter does not retain a")
    }

    func testFunctionWithoutDeclarationIsSkipped() throws {
        let (file, _, graph, _) = makeIndexedFile(source: source)
        try UnusedParameterAnalysis(configuration: Configuration()).apply(to: file)
        XCTAssertTrue(graph.allDeclarations.isEmpty)
    }
}

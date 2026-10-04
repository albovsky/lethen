import Configuration
@testable import Indexer
import Logger
import SourceGraph
import SwiftParser
import SwiftSyntax
@testable import SyntaxAnalysis
import SystemPackage

/// Builds an `IndexedFile` from a source string with no disk I/O. `references` are (line, column, kind, name).
func makeIndexedFile(
    source: String,
    modules: Set<String> = ["T"],
    declarations: [Declaration] = [],
    references: [(line: Int, column: Int, kind: Declaration.Kind, name: String)] = []
) -> (file: IndexedFile, sourceFile: SourceFile, graph: SourceGraph, evidence: ConfidenceEvidenceCollector) {
    let sourceFile = SourceFile(path: FilePath("/t/T.swift"), modules: modules)
    let syntax = Parser.parse(source: source)
    let converter = SourceLocationConverter(fileName: "/t/T.swift", tree: syntax)
    let builder = SourceLocationBuilder(file: sourceFile, locationConverter: converter)
    var byLocation: [Location: Set<Reference>] = [:]
    for (index, reference) in references.enumerated() {
        let location = Location(file: sourceFile, line: reference.line, column: reference.column)
        byLocation[location, default: []].insert(
            Reference(name: reference.name, kind: .normal, declarationKind: reference.kind, usr: "s:ref\(index)", location: location)
        )
    }
    let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
    let evidence = ConfidenceEvidenceCollector()
    let file = IndexedFile(
        syntax: syntax,
        locationBuilder: builder,
        declarations: declarations,
        referencesByLocation: byLocation,
        graph: SourceGraphMutex(graph: graph),
        evidence: evidence
    )
    return (file, sourceFile, graph, evidence)
}

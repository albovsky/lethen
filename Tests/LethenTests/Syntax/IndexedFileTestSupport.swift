@testable import Indexer
import SourceGraph
import SwiftParser
import SwiftSyntax
@testable import SyntaxAnalysis
import SystemPackage

/// Builds an `IndexedFile` from a source string with no disk I/O. `references` are (line, column, kind, name).
func makeIndexedFile(
    source: String,
    modules: Set<String> = ["T"],
    references: [(line: Int, column: Int, kind: Declaration.Kind, name: String)] = []
) -> (file: IndexedFile, sourceFile: SourceFile) {
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
    return (IndexedFile(syntax: syntax, locationBuilder: builder, referencesByLocation: byLocation), sourceFile)
}

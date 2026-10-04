import Configuration
@testable import Indexer
import SourceGraph
import SystemPackage
import XCTest

final class ValueUseAnalysisTest: XCTestCase {
    func testCallReferenceGetsTheReferencesOfItsArguments() throws {
        let source = "struct S {}\nlet v: S = S()\nf(v)\n"
        let (file, sourceFile, _, _) = makeIndexedFile(source: source, references: [
            (3, 1, .functionFree, "f(_:)"), // the call
            (2, 8, .struct, "S"), // the type the argument was declared with
            (9, 1, .functionFree, "nowhere"), // no syntax at this location
        ])
        try ValueUseAnalysis(configuration: Configuration()).apply(to: file)

        let call = try XCTUnwrap(file.references(at: Location(file: sourceFile, line: 3, column: 1)).first)
        XCTAssertEqual(call.valueArgumentReferences.map(\.name), ["S"])
        XCTAssertFalse(call.hasGenericValueArguments, "The control: S is not a generic parameter")
        let nowhere = try XCTUnwrap(file.references(at: Location(file: sourceFile, line: 9, column: 1)).first)
        XCTAssertTrue(nowhere.valueArgumentReferences.isEmpty)
    }

    func testGenericParameterAmongTheArgumentsIsFlagged() throws {
        let source = "func g<T>(_ x: T) {\n    let y: T = x\n    h(y)\n}\n"
        let (file, sourceFile, _, _) = makeIndexedFile(source: source, references: [
            (3, 5, .functionFree, "h(_:)"), // the call
            (2, 12, .genericTypeParam, "T"), // the generic parameter the argument was declared with
        ])
        try ValueUseAnalysis(configuration: Configuration()).apply(to: file)

        let call = try XCTUnwrap(file.references(at: Location(file: sourceFile, line: 3, column: 5)).first)
        XCTAssertEqual(call.valueArgumentReferences.map(\.name), ["T"])
        XCTAssertTrue(call.hasGenericValueArguments)
    }

    func testCallArgumentsKeepTheirLabelsAndSpecializationsResolveTheirTypes() throws {
        let source = "struct S {}\nlet v: S = S()\nf(a: v)\n"
        let (file, sourceFile, _, _) = makeIndexedFile(source: source, references: [
            (3, 1, .functionFree, "f(a:)"),
            (2, 8, .struct, "S"),
        ])
        try ValueUseAnalysis(configuration: Configuration()).apply(to: file)

        let call = try XCTUnwrap(file.references(at: Location(file: sourceFile, line: 3, column: 1)).first)
        XCTAssertEqual(call.valueArguments.map(\.label), ["a"])
        XCTAssertEqual(call.valueArguments.first?.references.map(\.name), ["S"])
    }

    func testDeclarationFactsAreRecordedByLocation() throws {
        let source = "var p: Int { 1 }\nlet c = 1\nvar stored = 2\n"
        let sourceFile = SourceFile(path: FilePath("/t/T.swift"), modules: ["T"])
        func declaration(_ name: String, line: Int) -> Declaration {
            Declaration(name: name, kind: .varGlobal, usrs: ["s:\(name)"], location: Location(file: sourceFile, line: line, column: 5))
        }
        let computed = declaration("p", line: 1)
        let constant = declaration("c", line: 2)
        let stored = declaration("stored", line: 3)
        let (file, _, _, _) = makeIndexedFile(source: source, declarations: [computed, constant, stored])
        try ValueUseAnalysis(configuration: Configuration()).apply(to: file)

        XCTAssertTrue(computed.hasAccessorBody)
        XCTAssertFalse(constant.hasAccessorBody)
        XCTAssertTrue(constant.isInitializedConstant)
        XCTAssertFalse(stored.isInitializedConstant, "The control: a var is not a constant")
        XCTAssertFalse(stored.hasAccessorBody)
    }
}

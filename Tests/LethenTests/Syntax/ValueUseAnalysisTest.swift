import Configuration
@testable import Indexer
import SourceGraph
import XCTest

final class ValueUseAnalysisTest: XCTestCase {
    func testCallReferenceGetsTheReferencesOfItsArguments() throws {
        let source = "struct S {}\nlet v: S = S()\nf(v)\n"
        let (file, sourceFile) = makeIndexedFile(source: source, references: [
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
        let (file, sourceFile) = makeIndexedFile(source: source, references: [
            (3, 5, .functionFree, "h(_:)"), // the call
            (2, 12, .genericTypeParam, "T"), // the generic parameter the argument was declared with
        ])
        try ValueUseAnalysis(configuration: Configuration()).apply(to: file)

        let call = try XCTUnwrap(file.references(at: Location(file: sourceFile, line: 3, column: 5)).first)
        XCTAssertEqual(call.valueArgumentReferences.map(\.name), ["T"])
        XCTAssertTrue(call.hasGenericValueArguments)
    }
}

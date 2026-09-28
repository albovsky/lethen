import SwiftParser
@testable import SyntaxAnalysis
import XCTest

final class EnumCasePatternSyntaxVisitorTest: XCTestCase {
    func testCollectsMemberNamesInsidePatterns() {
        let source = """
        switch value {
        case .matched, .other(let x): break
        case let .bound(y): break
        case Kind.qualified: break
        default: break
        }
        if case .conditional = value {}
        guard case .guarded = value else { return }
        for case .loop(.nested) in values {}
        _ = value == .compared
        _ = Kind.constructed
        """
        let visitor = EnumCasePatternSyntaxVisitor()
        visitor.walk(Parser.parse(source: source))
        XCTAssertEqual(visitor.memberNames, ["matched", "other", "bound", "qualified", "conditional", "guarded", "loop", "nested"])
    }
}

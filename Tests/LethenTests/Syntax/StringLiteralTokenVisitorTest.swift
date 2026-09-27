import SwiftParser
@testable import SyntaxAnalysis
import XCTest

final class StringLiteralTokenVisitorTest: XCTestCase {
    func testCollectsIdentifierTokensFromLiterals() {
        let tokens = collect("""
        let a = "handleTap:"
        let b = "Module.ClassName with spaces"
        let c = "interp \\(value) tail_1"
        let d = \"\"\"
            multi line
            \"\"\"
        """)
        XCTAssertEqual(tokens, ["handleTap", "Module", "ClassName", "with", "spaces", "interp", "tail_1", "multi", "line"])
    }

    func testIgnoresNumbersAndOperators() {
        XCTAssertEqual(collect(#"let a = "42 + 7 -> ok""#), ["ok"])
    }

    private func collect(_ source: String) -> Set<String> {
        let visitor = StringLiteralTokenVisitor()
        visitor.walk(Parser.parse(source: source))
        return visitor.tokens
    }
}

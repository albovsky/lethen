import SwiftParser
@testable import SyntaxAnalysis
import XCTest

final class StringLiteralTokenVisitorTest: XCTestCase {
    func testCollectsIdentifiersFromSymbolShapedLiterals() {
        let tokens = collect("""
        let a = "handleTap:"
        let b = "Module.ClassName"
        let c = "tableView:didSelectRowAtIndexPath:"
        let d = "user.name"
        let e = "plain_1"
        """)
        XCTAssertEqual(tokens, ["handleTap", "Module", "ClassName", "tableView", "didSelectRowAtIndexPath", "user", "name", "plain_1"])
    }

    /// Log messages and other prose name words, not symbols; counting them would mark most
    /// declarations with common names as `likely`.
    func testIgnoresProseInterpolationAndNumbers() {
        let tokens = collect("""
        let a = "Module.ClassName with spaces"
        let b = "interp \\(value) tail_1"
        let c = \"\"\"
            multi line
            \"\"\"
        let d = "42 + 7 -> ok"
        let e = "invalid line in file"
        let f = ""
        """)
        XCTAssertEqual(tokens, [])
    }

    private func collect(_ source: String) -> Set<String> {
        let visitor = StringLiteralTokenVisitor()
        visitor.walk(Parser.parse(source: source))
        return visitor.tokens
    }
}

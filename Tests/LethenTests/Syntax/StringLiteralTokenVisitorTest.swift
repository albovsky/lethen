import SwiftParser
@testable import SyntaxAnalysis
import XCTest

final class StringLiteralTokenVisitorTest: XCTestCase {
    func testCollectsIdentifiersFromSymbolShapedLiterals() {
        let visitor = walk("""
        let a = "handleTap:"
        let b = "Module.ClassName"
        let c = "tableView:didSelectRowAtIndexPath:"
        let d = "user.name"
        let e = "plain_1"
        let f = "a:b"
        let g = ":"
        """)
        XCTAssertEqual(visitor.tokens, ["Module", "ClassName", "user", "name", "plain_1"])
    }

    /// A selector names the one method whose whole selector it spells, so it is kept whole and its parts
    /// are not recorded: `title` is not named by `setTitle:forState:`.
    func testSelectorShapedLiteralsAreKeptWholeAndNotSplit() {
        let visitor = walk("""
        let a = "handleTap:"
        let b = "tableView:didSelectRowAtIndexPath:"
        let c = "user.name"
        let d = ":"
        """)
        XCTAssertEqual(visitor.selectors, ["handleTap:", "tableView:didSelectRowAtIndexPath:"])
        XCTAssertEqual(visitor.tokens, ["user", "name"])
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

    private func walk(_ source: String) -> StringLiteralTokenVisitor {
        let visitor = StringLiteralTokenVisitor()
        visitor.walk(Parser.parse(source: source))
        return visitor
    }

    private func collect(_ source: String) -> Set<String> {
        let visitor = walk(source)
        return visitor.tokens.union(visitor.selectors)
    }
}

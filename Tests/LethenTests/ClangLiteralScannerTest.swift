@testable import Indexer
import XCTest

final class ClangLiteralScannerTest: XCTestCase {
    private func tokens(_ source: String) -> Set<String> {
        ClangLiteralScanner.tokens(in: source)
    }

    func testSelectorStringsAreSplitAtColons() {
        XCTAssertEqual(tokens(#"NSSelectorFromString(@"handleTap:");"#), ["handleTap"])
        XCTAssertEqual(tokens(#"[o valueForKey:@"kvcRead"];"#), ["kvcRead"])
    }

    func testQualifiedNamesAreSplitAtDots() {
        XCTAssertEqual(tokens(#"NSClassFromString(@"Module.Name");"#), ["Module", "Name"])
        XCTAssertEqual(tokens(#"const char *c = "plain_c";"#), ["plain_c"])
    }

    func testSelectorExpressionsCount() {
        XCTAssertEqual(tokens("SEL s = @selector(didTap:with:);"), ["didTap", "with"])
        XCTAssertEqual(tokens("SEL s = @selector( didTap: );"), ["didTap"])
        XCTAssertEqual(tokens("SEL s = @selector (plain);"), ["plain"])
    }

    func testProseStringsAreSkipped() {
        XCTAssertEqual(tokens(#"NSLog(@"Tapped the button %@", x); NSLog(@"");"#), [])
    }

    func testEscapedQuotesStayInsideTheStringAndMakeItProse() {
        XCTAssertEqual(tokens(#"a = @"say \"hello\""; b = @"after";"#), ["after"])
        XCTAssertEqual(tokens(#"a = @"back\\"; b = @"next";"#), ["next"])
    }

    func testCommentsAreSkipped() {
        XCTAssertEqual(tokens("// @selector(notMe)\nint x;"), [])
        XCTAssertEqual(tokens(#"/* "notMe" */ int x;"#), [])
        XCTAssertEqual(tokens("/* a\n @selector(notMe)\n */ SEL s = @selector(me);"), ["me"])
        XCTAssertEqual(tokens(#"int x; // "trailing"# + "\n" + #"a = @"kept";"#), ["kept"])
    }

    func testIncludeAndImportLinesAreSkipped() {
        XCTAssertEqual(tokens("#import \"NotAToken.h\"\n#include \"Neither.h\"\n  #  import \"Nor.h\"\na = @\"token\";"), ["token"])
    }

    func testOtherDirectivesAreScannedAsCode() {
        XCTAssertEqual(tokens("#define KEY @\"keyName\"\n"), ["keyName"])
    }

    func testCharacterLiteralsDoNotOpenStrings() {
        XCTAssertEqual(tokens(#"char c = '"'; a = @"name"; char d = '\'';"#), ["name"])
    }

    func testUnterminatedConstructsDoNotHangOrCrash() {
        XCTAssertEqual(tokens(#"a = @"unterminated"#), ["unterminated"])
        XCTAssertEqual(tokens("a = @\"open\nb = @\"next\";"), ["open", "next"])
        XCTAssertEqual(tokens("/* never closed @selector(x)"), [])
        XCTAssertEqual(tokens("a = @selector(unclosed"), ["unclosed"])
        XCTAssertEqual(tokens("a = @selector"), [])
        XCTAssertEqual(tokens("'"), [])
        XCTAssertEqual(tokens("\\"), [])
        XCTAssertEqual(tokens(#"@""#), [])
        XCTAssertEqual(tokens(""), [])
    }

    /// Clang compiles a file with a stray non-UTF-8 byte, so the scanner must not give up on it.
    func testBytesThatAreNotUTF8CostOnlyTheirOwnLiteral() {
        var bytes = Array("// caf".utf8) + [0xE9] + Array("\nSEL s = @selector(afterComment);\n".utf8)
        bytes += Array("a = @\"caf".utf8) + [0xE9] + Array("\"; b = @\"afterLiteral\";\n".utf8)
        XCTAssertEqual(ClangLiteralScanner.tokens(in: bytes), ["afterComment", "afterLiteral"])
    }
}

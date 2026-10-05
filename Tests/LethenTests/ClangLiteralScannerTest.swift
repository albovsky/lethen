@testable import Indexer
import SystemPackage
import XCTest

final class ClangLiteralScannerTest: XCTestCase {
    private func tokens(_ source: String) -> Set<String> {
        ClangLiteralScanner.names(in: Array(source.utf8)).tokens
    }

    private func selectors(_ source: String) -> Set<String> {
        ClangLiteralScanner.names(in: Array(source.utf8)).selectors
    }

    func testSelectorStringsAreKeptWhole() {
        XCTAssertEqual(selectors(#"NSSelectorFromString(@"handleTap:");"#), ["handleTap:"])
        XCTAssertEqual(tokens(#"NSSelectorFromString(@"handleTap:");"#), [])
        XCTAssertEqual(selectors(#"NSSelectorFromString(@"setTitle:forState:");"#), ["setTitle:forState:"])
        XCTAssertEqual(tokens(#"[o valueForKey:@"kvcRead"];"#), ["kvcRead"])
        XCTAssertEqual(selectors(#"[o valueForKey:@"kvcRead"];"#), [])
    }

    func testStringWithAColonAndNoIdentifierNamesNothing() {
        XCTAssertEqual(selectors(#"a = @"a:b";"#), ["a:b"])
        XCTAssertEqual(selectors(#"b = @":"; c = @"::"; d = @"1:";"#), [])
        XCTAssertEqual(tokens(#"b = @":"; c = @"::"; d = @"1:";"#), [])
    }

    func testQualifiedNamesAreSplitAtDots() {
        XCTAssertEqual(tokens(#"NSClassFromString(@"Module.Name");"#), ["Module", "Name"])
        XCTAssertEqual(tokens(#"const char *c = "plain_c";"#), ["plain_c"])
    }

    func testSelectorExpressionsCount() {
        XCTAssertEqual(selectors("SEL s = @selector(didTap:with:);"), ["didTap:with:"])
        XCTAssertEqual(tokens("SEL s = @selector(didTap:with:);"), [])
        XCTAssertEqual(selectors("SEL s = @selector( didTap: );"), ["didTap:"])
        XCTAssertEqual(selectors("SEL s = @selector (plain);"), ["plain"])
    }

    func testProseStringsAreSkipped() {
        XCTAssertEqual(tokens(#"NSLog(@"Tapped the button %@", x); NSLog(@"");"#), [])
    }

    /// Clang evaluates escapes, so the runtime sees `foo` however the source spells it.
    func testEscapesAreDecodedBeforeMatching() {
        XCTAssertEqual(tokens(#"NSSelectorFromString(@"f\x6fo");"#), ["foo"])
        XCTAssertEqual(selectors(#"NSSelectorFromString(@"\146oo:");"#), ["foo:"])
        XCTAssertEqual(tokens(#"NSClassFromString(@"Caf\u00e9");"#), ["Café"])
        XCTAssertEqual(tokens(#"NSClassFromString(@"Caf\U000000e9");"#), ["Café"])
        // A tab is not part of a name, and an escape the compiler rejects stands for itself.
        XCTAssertEqual(tokens(#"a = @"f\too"; b = @"f\qoo"; c = @"\x"; d = @"after";"#), ["after"])
    }

    /// The preprocessor removes a backslash before a newline before it sees any token.
    func testEscapedNewlinesAreSpliced() {
        XCTAssertEqual(tokens("x = @\"renamed\\\nForObjC\";"), ["renamedForObjC"])
        XCTAssertEqual(selectors("SEL s = @sel\\\nector(spliced);"), ["spliced"])
        XCTAssertEqual(tokens("x = @\"renamed\\\r\nForObjC\";"), ["renamedForObjC"])
    }

    /// Comments are whitespace to the preprocessor, inside a selector expression as well.
    func testCommentsInSelectorExpressionsAreWhitespace() {
        XCTAssertEqual(selectors("SEL s = @selector /* note */ (commented:);"), ["commented:"])
        XCTAssertEqual(selectors("SEL s = @selector(inner /* note */ :with:);"), ["inner:with:"])
        XCTAssertEqual(selectors("SEL s = @selector(first:\n    second:);"), ["first:second:"])
        XCTAssertEqual(selectors("SEL s = @selector(\n    leadingNewline:);"), ["leadingNewline:"])
        // A selector left open ends at a blank line and still counts, which errs towards likely.
        XCTAssertEqual(selectors("SEL s = @selector(open\n\nSEL t = @selector(closed);"), ["open", "closed"])
    }

    /// A raw string in an Objective-C++ file has no escapes and its delimiters are not part of the text.
    func testRawStringLiteralsAreReadWithoutTheirDelimiters() {
        XCTAssertEqual(tokens(#"sel_registerName(R"(rawName)");"#), ["rawName"])
        XCTAssertEqual(tokens(#"x = R"x(withDelimiter)x"; y = u8R"(prefixed)"; z = LR"(wide)";"#), ["withDelimiter", "prefixed", "wide"])
        XCTAssertEqual(tokens("x = R\"(multi\nline)\"; y = @\"after\";"), ["after"])
        // Raw and ordinary literals concatenate like any adjacent literals.
        XCTAssertEqual(tokens(#"sel_registerName(R"(renamed)" "ForObjC");"#), ["renamedForObjC"])
        XCTAssertEqual(tokens(#"x = @"renamed" u8R"(ForObjC)";"#), ["renamedForObjC"])
        // An identifier ending in R is not a raw string prefix.
        XCTAssertEqual(tokens(#"FOOBAR"(notRaw)"; x = @"ordinary";"#), ["ordinary"])
    }

    /// The compiler joins adjacent literals into one string.
    func testAdjacentLiteralsAreOneString() {
        XCTAssertEqual(tokens(#"NSClassFromString(@"Renamed" @"Class");"#), ["RenamedClass"])
        XCTAssertEqual(selectors("x = \"split\"\n    \"Name:\";"), ["splitName:"])
        // Comments are whitespace to the compiler.
        XCTAssertEqual(tokens(#"NSClassFromString(@"Renamed" /* note */ @"Class");"#), ["RenamedClass"])
        XCTAssertEqual(tokens("x = @\"Renamed\" // note\n    @\"Class\";"), ["RenamedClass"])
        // The control: a comma separates two strings.
        XCTAssertEqual(tokens(#"f(@"first", @"second");"#), ["first", "second"])
    }

    func testFilesThatCannotBeReadAreReported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readable = directory.appendingPathComponent("Readable.m")
        try #"SEL s = @selector(readableSelector);"#.write(to: readable, atomically: true, encoding: .utf8)
        let missing = directory.appendingPathComponent("Missing.m")

        let result = ClangLiteralScanner.scan(files: [FilePath(readable.path), FilePath(missing.path)])
        XCTAssertEqual(result.names.selectors, ["readableSelector"])
        XCTAssertEqual(result.names.tokens, [])
        XCTAssertEqual(result.unreadFiles, [FilePath(missing.path)])
    }

    func testEscapedQuotesStayInsideTheStringAndMakeItProse() {
        XCTAssertEqual(tokens(#"a = @"say \"hello\""; b = @"after";"#), ["after"])
        XCTAssertEqual(tokens(#"a = @"back\\"; b = @"next";"#), ["next"])
    }

    func testCommentsAreSkipped() {
        XCTAssertEqual(selectors("// @selector(notMe)\nint x;"), [])
        XCTAssertEqual(tokens(#"/* "notMe" */ int x;"#), [])
        XCTAssertEqual(selectors("/* a\n @selector(notMe)\n */ SEL s = @selector(me);"), ["me"])
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
        XCTAssertEqual(selectors("/* never closed @selector(x)"), [])
        XCTAssertEqual(selectors("a = @selector(unclosed"), ["unclosed"])
        XCTAssertEqual(selectors("a = @selector"), [])
        XCTAssertEqual(tokens("'"), [])
        XCTAssertEqual(tokens("\\"), [])
        XCTAssertEqual(tokens(#"@""#), [])
        XCTAssertEqual(ClangLiteralScanner.names(in: []), ClangLiteralScanner.Names())
    }

    /// Clang compiles a file with a stray non-UTF-8 byte, so the scanner must not give up on it.
    func testBytesThatAreNotUTF8CostOnlyTheirOwnLiteral() {
        var bytes = Array("// caf".utf8) + [0xE9] + Array("\nSEL s = @selector(afterComment);\n".utf8)
        bytes += Array("a = @\"caf".utf8) + [0xE9] + Array("\"; b = @\"afterLiteral\";\n".utf8)
        let names = ClangLiteralScanner.names(in: bytes)
        XCTAssertEqual(names.selectors, ["afterComment"])
        XCTAssertEqual(names.tokens, ["afterLiteral"])
    }
}

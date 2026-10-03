@testable import Indexer
@testable import SourceGraph
import SystemPackage
import XCTest

final class ClangImportScannerTest: XCTestCase {
    private let file = SourceFile(path: FilePath("/project/File.m"), modules: [])

    private func imports(_ source: String) -> [ImportStatement] {
        ClangImportScanner.imports(in: Array(source.utf8), file: file)
    }

    func testFindsPlainImport() throws {
        let statement = try XCTUnwrap(imports("@import WMF;\n").first)

        XCTAssertEqual(statement.module, "WMF")
        XCTAssertEqual(statement.qualifiedModule, "WMF")
        XCTAssertFalse(statement.isConditional)
        XCTAssertFalse(statement.isTestable)
        XCTAssertFalse(statement.isExported)
        XCTAssertEqual(statement.commentCommands, [])
    }

    func testSubmodulePathKeepsTheTopLevelModule() throws {
        let statement = try XCTUnwrap(imports("@import WMF.WMFLogging;").first)

        XCTAssertEqual(statement.module, "WMF")
        XCTAssertEqual(statement.qualifiedModule, "WMF.WMFLogging")
    }

    func testWhitespaceAroundDotsAndSemicolon() throws {
        let statement = try XCTUnwrap(imports("@import   WMF . WMFLogging\t;").first)

        XCTAssertEqual(statement.qualifiedModule, "WMF.WMFLogging")
    }

    func testLineAndColumnPointAtTheAtSign() throws {
        let source = "#import <Foundation/Foundation.h>\n\n  @import Foundation;\nint x;\n\t@import WMF;\n"
        let found = imports(source)

        XCTAssertEqual(found.map(\.qualifiedModule), ["Foundation", "WMF"])
        XCTAssertEqual(found.map(\.location.line), [3, 5])
        XCTAssertEqual(found.map(\.location.column), [3, 2])
    }

    func testLineNumbersCountSplicedLines() throws {
        let statement = try XCTUnwrap(imports("#define A \\\n  1\n@import WMF;\n").first)

        XCTAssertEqual(statement.location.line, 3)
    }

    /// The column counts from the physical line, not the logical one the splice joined.
    func testColumnAfterASplicedLine() throws {
        let statement = try XCTUnwrap(imports("  \\\n\t@import WMF;\n").first)

        XCTAssertEqual(statement.location.line, 2)
        XCTAssertEqual(statement.location.column, 2)
    }

    /// Blanks and block comments may stand between `#` and the directive name.
    func testConditionalDirectiveWithACommentAfterTheHash() {
        let conditional = imports("# /* guard */ if FLAG\n@import A;\n#\t/* x */ endif\n@import B;\n")
            .map { ($0.module, $0.isConditional) }

        XCTAssertEqual(conditional.map(\.0), ["A", "B"])
        XCTAssertEqual(conditional.map(\.1), [true, false])
    }

    func testImportSplitAcrossSplicedLines() throws {
        let statement = try XCTUnwrap(imports("@import WMF.\\\nWMFLogging;\n").first)

        XCTAssertEqual(statement.qualifiedModule, "WMF.WMFLogging")
    }

    func testImportsInCommentsAndStringsAreNotFound() {
        XCTAssertEqual(imports("// @import WMF;\n").count, 0)
        XCTAssertEqual(imports("/* @import WMF;\n@import Other; */\n").count, 0)
        XCTAssertEqual(imports(#"NSString *s = @"@import WMF;";"#).count, 0)
        XCTAssertEqual(imports("char c = '@'; // @import WMF;\n").count, 0)
        XCTAssertEqual(imports("const char *s = R\"(@import WMF;)\";\n").count, 0)
    }

    func testImportAfterCommentsIsFound() {
        XCTAssertEqual(imports("/* a */ @import WMF; // b\n@import Other;\n").map(\.module), ["WMF", "Other"])
    }

    func testHeaderImportsAreNotModuleImports() {
        XCTAssertEqual(imports("#import <WMF/WMF.h>\n#import \"WMF.h\"\n#include <WMF/WMF.h>\n").count, 0)
    }

    func testMalformedImportsAreNotFound() {
        XCTAssertEqual(imports("@importFoo;\n").count, 0)
        XCTAssertEqual(imports("@import;\n").count, 0)
        XCTAssertEqual(imports("@import WMF\n").count, 0)
        XCTAssertEqual(imports("@import WMF.;\n").count, 0)
        XCTAssertEqual(imports("@import 1WMF;\n").count, 0)
    }

    func testConditionalImports() {
        let source = """
        @import A;
        #if FLAG
        @import B;
        #if NESTED
        @import C;
        #endif
        @import D;
        #endif
        @import E;
        #ifdef X
          # endif
        @import F;
        #ifndef Y
        @import G;
        #else
        @import H;
        #endif
        """
        let conditional = Dictionary(uniqueKeysWithValues: imports(source).map { ($0.module, $0.isConditional) })

        XCTAssertEqual(conditional, [
            "A": false, "B": true, "C": true, "D": true, "E": false, "F": false, "G": true, "H": true,
        ])
    }

    /// A comment is one space to the preprocessor, so a directive after one on the same line still counts.
    func testConditionalDirectiveAfterABlockComment() {
        let source = "/* note */ #if FLAG\n@import A;\n#endif\n/* spans\nlines */ #if OTHER\n@import B;\n#endif\n@import C;\n"
        let conditional = Dictionary(uniqueKeysWithValues: imports(source).map { ($0.module, $0.isConditional) })

        XCTAssertEqual(conditional, ["A": true, "B": true, "C": false])
    }

    func testIgnoreCommandInABlockCommentSpanningLinesAbove() throws {
        let found = imports("/* periphery:ignore\n */\n@import WMF;\n/* periphery:ignore */\n\n@import Other;\n")

        XCTAssertEqual(found.map(\.commentCommands), [[.ignore], [.ignore]])
    }

    /// A block comment that trails other code belongs to that code.
    func testBlockCommentTrailingOtherCodeIsNotACommandForTheNextImport() throws {
        let statement = try XCTUnwrap(imports("int x; /* periphery:ignore */\n@import WMF;\n").first)

        XCTAssertEqual(statement.commentCommands, [])
    }

    func testFileWideIgnoreCommandReachesEveryImport() {
        let found = imports("// periphery:ignore:all\n@import A;\n@import B; // periphery:ignore\n")

        XCTAssertEqual(found.map(\.commentCommands), [[.ignoreAll], [.ignore, .ignoreAll]])
        XCTAssertEqual(imports("@import A;\n/* periphery:ignore:all */\n").map(\.commentCommands), [[.ignoreAll]])
    }

    /// The header name of an include is skipped, but a comment after it is still a comment, and a
    /// block comment that starts on an include line continues past it.
    func testFileWideIgnoreCommandOnAnIncludeLine() {
        let found = imports("#import \"Header.h\" // periphery:ignore:all\n@import A;\n")

        XCTAssertEqual(found.map(\.commentCommands), [[.ignoreAll]])
        XCTAssertEqual(imports("#include <A//ignore:all.h>\n@import A;\n").map(\.commentCommands), [[]])
        XCTAssertEqual(imports("#include <A.h> /* periphery:ignore:all\n */\n@import A;\n").map(\.commentCommands), [[.ignoreAll]])
        XCTAssertEqual(imports("#include <A.h> /* see\n@import Other;\n*/\n@import A;\n").map(\.module), ["A"])
    }

    /// A macro's replacement list imports nothing until the macro is used, which the index shows.
    func testImportsInMacroDefinitionsAreNotFound() {
        XCTAssertEqual(imports("#define OPTIONAL_IMPORT @import A;\n@import B;\n").map(\.module), ["B"])
        XCTAssertEqual(imports("#define S \"\\\" @import X; \"\n@import B;\n").map(\.module), ["B"])
        XCTAssertEqual(imports("#pragma mark - @import X;\n@import B; // periphery:ignore\n").map(\.commentCommands), [[.ignore]])
    }

    func testIgnoreCommandOnTheSameLine() throws {
        let statement = try XCTUnwrap(imports("@import WMF; // periphery:ignore\n").first)

        XCTAssertEqual(statement.commentCommands, [.ignore])
    }

    func testIgnoreCommandInBlockCommentOnTheSameLine() throws {
        let statement = try XCTUnwrap(imports("@import WMF; /* periphery:ignore */\n").first)

        XCTAssertEqual(statement.commentCommands, [.ignore])
    }

    func testIgnoreCommandOnThePreviousLine() throws {
        let statement = try XCTUnwrap(imports("// periphery:ignore\n@import WMF;\n").first)

        XCTAssertEqual(statement.commentCommands, [.ignore])
    }

    func testCommentCommandsDoNotReachOtherImports() {
        let found = imports("// periphery:ignore\n@import A;\n@import B;\n@import C; // periphery:ignore\n@import D;\n")

        XCTAssertEqual(found.map(\.commentCommands), [[.ignore], [], [.ignore], []])
    }

    /// A comment that trails other code belongs to that code, as trivia does in Swift.
    func testCommentTrailingOtherCodeIsNotACommandForTheNextImport() throws {
        let statement = try XCTUnwrap(imports("int x; // periphery:ignore\n@import WMF;\n").first)

        XCTAssertEqual(statement.commentCommands, [])
    }

    func testOrdinaryCommentsAreNotCommands() throws {
        let statement = try XCTUnwrap(imports("// needed for the logger\n@import WMF; // keep\n").first)

        XCTAssertEqual(statement.commentCommands, [])
    }

    func testCarriageReturnLineEndings() throws {
        let found = imports("@import A; // periphery:ignore\r\n@import B;\r\n")

        XCTAssertEqual(found.map(\.location.line), [1, 2])
        XCTAssertEqual(found.map(\.commentCommands), [[.ignore], []])
    }
}

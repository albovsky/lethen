import Foundation
import SourceGraph
import SyntaxAnalysis

/// Finds the `@import A.B.C;` statements of a C or Objective-C file. Clang's index records no
/// occurrence for an `@import`, and the Swift syntax visitor does not parse these files, so the
/// statements and their locations come from the text.
///
/// Only the modular `@import` form counts: a `#import <A/B.h>` or `#include` names a header, and
/// whether it is needed is a question about headers rather than modules. Like `ClangLiteralScanner`,
/// it is a single pass over the bytes that skips comments and string and character literals, and it
/// does not expand macros, so an import inside a `#if` block is reported as conditional rather than
/// evaluated.
enum ClangImportScanner {
    private static let semicolon = UInt8(ascii: ";")
    private static let dot = UInt8(ascii: ".")
    private static let keyword = Array("import".utf8)
    private static let conditionalOpeners: Set<String> = ["if", "ifdef", "ifndef"]

    static func imports(in source: [UInt8], file: SourceFile) -> [ImportStatement] {
        let (bytes, splices) = ClangLiteralScanner.splicingLines(source)
        var statements: [ImportStatement] = []
        var index = 0
        var atLineStart = true
        var conditionalDepth = 0
        // `// periphery:ignore:all` anywhere in the file ignores the whole file, imports included, as the
        // Swift indexer reads it from any comment of the file.
        var ignoresAll = false

        while index < bytes.count {
            let byte = bytes[index]
            let wasAtLineStart = atLineStart
            atLineStart = byte == ClangLiteralScanner.newline || (wasAtLineStart && ClangLiteralScanner.isBlank(byte))

            switch byte {
            case ClangLiteralScanner.hash where wasAtLineStart:
                let directive = directiveName(after: index, in: bytes)
                if conditionalOpeners.contains(directive) {
                    conditionalDepth += 1
                } else if directive == "endif" {
                    conditionalDepth = max(0, conditionalDepth - 1)
                }
                // The rest of a directive is not code: a header name such as `<A//B.h>`, or a macro's
                // replacement list, which imports nothing until the macro is used. Its comments still are.
                index = endOfDirective(from: index, in: bytes, isInclude: ClangLiteralScanner.isIncludeDirective(at: index, in: bytes), ignoresAll: &ignoresAll)
            case ClangLiteralScanner.slash where bytes[safe: index + 1] == ClangLiteralScanner.slash:
                let end = ClangLiteralScanner.endOfLine(from: index, in: bytes)
                ignoresAll = ignoresAll || CommentCommand.parseCommand(inComment: text(bytes[index ..< end])) == .ignoreAll
                index = end
            case ClangLiteralScanner.slash where bytes[safe: index + 1] == ClangLiteralScanner.star:
                // The preprocessor replaces a comment with one space before it looks for directives, so
                // `/* note */ #if FLAG` is a directive and a comment spanning lines does not end one.
                let end = ClangLiteralScanner.endOfBlockComment(from: index + 2, in: bytes)
                ignoresAll = ignoresAll || CommentCommand.parseCommand(inComment: text(bytes[index ..< end])) == .ignoreAll
                index = end
                atLineStart = wasAtLineStart
            case ClangLiteralScanner.quote:
                index = ClangLiteralScanner.anyStringLiteral(openingQuoteAt: index, in: bytes).next
            case ClangLiteralScanner.apostrophe:
                index = ClangLiteralScanner.endOfCharacterLiteral(from: index + 1, in: bytes)
            case ClangLiteralScanner.at where keywordEnd(after: index, in: bytes) != nil:
                let afterKeyword = keywordEnd(after: index, in: bytes) ?? index + 1
                if let (path, end) = modulePath(from: afterKeyword, in: bytes) {
                    let location = location(of: index, in: bytes, splices: splices, file: file)
                    statements.append(ImportStatement(
                        module: path.first ?? "",
                        qualifiedModule: path.joined(separator: "."),
                        isTestable: false,
                        isExported: false,
                        isConditional: conditionalDepth > 0,
                        location: location,
                        commentCommands: commentCommands(forStatementAt: index, keywordStart: afterKeyword - keyword.count, endingBefore: end, in: bytes)
                    ))
                    index = end
                } else {
                    index = afterKeyword
                }
            default:
                index += 1
            }
        }

        guard ignoresAll else { return statements }

        return statements.map { statement in
            guard !statement.commentCommands.contains(.ignoreAll) else { return statement }

            return ImportStatement(
                module: statement.module,
                qualifiedModule: statement.qualifiedModule,
                isTestable: statement.isTestable,
                isExported: statement.isExported,
                isConditional: statement.isConditional,
                location: statement.location,
                commentCommands: statement.commentCommands + [.ignoreAll]
            )
        }
    }

    // MARK: - Private

    /// The slice as text; a slice that is not UTF-8 is empty, so it names no module and holds no command.
    private static func text(_ slice: ArraySlice<UInt8>) -> String {
        String(bytes: slice, encoding: .utf8) ?? ""
    }

    /// The index of the newline that ends the directive at `index`, or the end of the file. String and
    /// character literals, and an include's `<header name>`, are skipped as such, a `//` comment ends
    /// the directive, and a block comment continues past the newlines it spans. Each comment is read
    /// for a file-wide ignore command.
    private static func endOfDirective(from index: Int, in bytes: [UInt8], isInclude: Bool, ignoresAll: inout Bool) -> Int {
        var cursor = index + 1
        var afterName = false
        while cursor < bytes.count {
            let byte = bytes[cursor]
            switch byte {
            case ClangLiteralScanner.newline:
                return cursor
            case ClangLiteralScanner.slash where bytes[safe: cursor + 1] == ClangLiteralScanner.slash:
                let end = ClangLiteralScanner.endOfLine(from: cursor, in: bytes)
                ignoresAll = ignoresAll || CommentCommand.parseCommand(inComment: text(bytes[cursor ..< end])) == .ignoreAll
                return end
            case ClangLiteralScanner.slash where bytes[safe: cursor + 1] == ClangLiteralScanner.star:
                let end = ClangLiteralScanner.endOfBlockComment(from: cursor + 2, in: bytes)
                ignoresAll = ignoresAll || CommentCommand.parseCommand(inComment: text(bytes[cursor ..< end])) == .ignoreAll
                cursor = end
            case ClangLiteralScanner.quote:
                cursor = ClangLiteralScanner.anyStringLiteral(openingQuoteAt: cursor, in: bytes).next
            case ClangLiteralScanner.apostrophe:
                cursor = ClangLiteralScanner.endOfCharacterLiteral(from: cursor + 1, in: bytes)
            case UInt8(ascii: "<") where isInclude && afterName:
                cursor = (bytes[cursor...].firstIndex(of: UInt8(ascii: ">")) ?? bytes.count - 1) + 1
            default:
                afterName = afterName || ClangLiteralScanner.isIdentifierByte(byte)
                cursor += 1
            }
        }
        return bytes.count
    }

    /// The lowercase name after the `#` at `index`, such as `ifdef`, or an empty string. Blanks and
    /// block comments may stand between them (`# /* guard */ if FLAG`); a newline ends the directive.
    private static func directiveName(after index: Int, in bytes: [UInt8]) -> String {
        var cursor = index + 1
        while cursor < bytes.count {
            if ClangLiteralScanner.isBlank(bytes[cursor]) {
                cursor += 1
            } else if bytes[cursor] == ClangLiteralScanner.slash, bytes[safe: cursor + 1] == ClangLiteralScanner.star {
                cursor = ClangLiteralScanner.endOfBlockComment(from: cursor + 2, in: bytes)
            } else {
                break
            }
        }

        let start = cursor
        while cursor < bytes.count, bytes[cursor] >= UInt8(ascii: "a"), bytes[cursor] <= UInt8(ascii: "z") {
            cursor += 1
        }

        return text(bytes[start ..< cursor])
    }

    /// The index after the `import` keyword of the `@import` whose `@` is at `index`, or `nil` when the `@`
    /// starts something else. Blanks and comments may stand between the `@` and the keyword, as the
    /// preprocessor turns them into whitespace and the compiler reads `@ import` as one directive.
    private static func keywordEnd(after index: Int, in bytes: [UInt8]) -> Int? {
        let cursor = ClangLiteralScanner.skippingBlanksAndComments(from: index + 1, in: bytes)
        return bytes[cursor...].starts(with: keyword) ? cursor + keyword.count : nil
    }

    /// The identifiers of the dotted path that follows `@import` at `index`, and the index after the
    /// closing semicolon, or `nil` when the text is not an import statement. The preprocessor turns
    /// comments into whitespace, so they may stand between the tokens, but the keyword must be set
    /// apart from the name: `@importFoo` is not an import.
    private static func modulePath(from index: Int, in bytes: [UInt8]) -> (path: [String], end: Int)? {
        var cursor = ClangLiteralScanner.skippingBlanksAndComments(from: index, in: bytes)
        guard cursor > index else { return nil }

        var path: [String] = []
        while true {
            let start = cursor
            guard let first = bytes[safe: cursor], isIdentifierStart(first) else { return nil }

            while cursor < bytes.count, ClangLiteralScanner.isIdentifierByte(bytes[cursor]) || bytes[cursor] >= 0x80 {
                cursor += 1
            }
            path.append(text(bytes[start ..< cursor]))

            cursor = ClangLiteralScanner.skippingBlanksAndComments(from: cursor, in: bytes)
            if bytes[safe: cursor] == dot {
                cursor = ClangLiteralScanner.skippingBlanksAndComments(from: cursor + 1, in: bytes)
            } else {
                break
            }
        }

        guard bytes[safe: cursor] == semicolon else { return nil }

        return (path, cursor + 1)
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        ClangLiteralScanner.isIdentifierByte(byte) && !(byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte >= 0x80
    }

    /// The line and column of the byte at `index`. Lines count the backslash-newline pairs that were
    /// spliced out, and the column counts from the last of a newline or a splice, so both match the
    /// file as the editor and the index show it.
    private static func location(of index: Int, in bytes: [UInt8], splices: [Int], file: SourceFile) -> Location {
        let splicesBefore = splices.prefix(while: { $0 <= index })
        var line = 1 + splicesBefore.count
        var lineStart = 0
        for position in 0 ..< index where bytes[position] == ClangLiteralScanner.newline {
            line += 1
            lineStart = position + 1
        }
        lineStart = max(lineStart, splicesBefore.last ?? 0)
        return Location(file: file, line: line, column: index - lineStart + 1)
    }

    /// The commands in comments between its `@` and keyword, that trail the statement on its line, and in the comment directly above
    /// it, as Swift's leading and trailing trivia are read: a `//` line, or a block comment, which may
    /// span lines, that only whitespace separates from the statement's line.
    private static func commentCommands(
        forStatementAt index: Int,
        keywordStart: Int,
        endingBefore end: Int,
        in bytes: [UInt8]
    ) -> [CommentCommand] {
        // Comments between the `@` and the keyword belong to the statement too.
        var comments: [String] = [text(bytes[(index + 1) ..< keywordStart]).trimmingCharacters(in: .whitespacesAndNewlines)]

        var cursor = end
        while cursor < bytes.count {
            while cursor < bytes.count, ClangLiteralScanner.isBlank(bytes[cursor]) {
                cursor += 1
            }

            let next: Int
            if bytes[safe: cursor] == ClangLiteralScanner.slash, bytes[safe: cursor + 1] == ClangLiteralScanner.slash {
                next = ClangLiteralScanner.endOfLine(from: cursor, in: bytes)
            } else if bytes[safe: cursor] == ClangLiteralScanner.slash, bytes[safe: cursor + 1] == ClangLiteralScanner.star {
                next = ClangLiteralScanner.endOfBlockComment(from: cursor + 2, in: bytes)
            } else {
                break
            }
            comments.append(text(bytes[cursor ..< next]))
            cursor = next
        }

        let lineStart = (bytes[..<index].lastIndex(of: ClangLiteralScanner.newline) ?? -1) + 1
        if let leading = leadingComment(endingBefore: lineStart, in: bytes) {
            comments.append(leading)
        }

        return comments.compactMap { CommentCommand.parseCommand(inComment: $0) }
    }

    /// The comment that ends, up to whitespace, right before `lineStart`: a `//` comment on the line
    /// above, or a block comment, which may span several lines.
    private static func leadingComment(endingBefore lineStart: Int, in bytes: [UInt8]) -> String? {
        var end = lineStart
        while end > 0, ClangLiteralScanner.isBlank(bytes[end - 1]) || bytes[end - 1] == ClangLiteralScanner.newline {
            end -= 1
        }
        guard end > 0 else { return nil }

        if end >= 2, bytes[end - 2] == ClangLiteralScanner.star, bytes[end - 1] == ClangLiteralScanner.slash {
            var start = end - 2
            while start > 0 {
                start -= 1
                if bytes[start] == ClangLiteralScanner.slash, bytes[start + 1] == ClangLiteralScanner.star {
                    // A comment that trails other code belongs to that code.
                    let commentLineStart = (bytes[..<start].lastIndex(of: ClangLiteralScanner.newline) ?? -1) + 1
                    guard bytes[commentLineStart ..< start].allSatisfy(ClangLiteralScanner.isBlank) else { return nil }

                    return text(bytes[start ..< end])
                }
            }
            return nil
        }

        let previousStart = (bytes[..<end].lastIndex(of: ClangLiteralScanner.newline) ?? -1) + 1
        let previous = text(bytes[previousStart ..< end]).trimmingCharacters(in: .whitespaces)
        return previous.hasPrefix("//") ? previous : nil
    }
}

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
    private static let keyword = Array("@import".utf8)
    private static let conditionalOpeners: Set<String> = ["if", "ifdef", "ifndef"]

    static func imports(in source: [UInt8], file: SourceFile) -> [ImportStatement] {
        let (bytes, splices) = ClangLiteralScanner.splicingLines(source)
        var statements: [ImportStatement] = []
        var index = 0
        var atLineStart = true
        var conditionalDepth = 0

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
                // A header name such as `<A//B.h>` is not code, and other directives are scanned as code.
                index = ClangLiteralScanner.isIncludeDirective(at: index, in: bytes)
                    ? ClangLiteralScanner.endOfLine(from: index, in: bytes) : index + 1
            case ClangLiteralScanner.slash where bytes[safe: index + 1] == ClangLiteralScanner.slash:
                index = ClangLiteralScanner.endOfLine(from: index, in: bytes)
            case ClangLiteralScanner.slash where bytes[safe: index + 1] == ClangLiteralScanner.star:
                index = ClangLiteralScanner.endOfBlockComment(from: index + 2, in: bytes)
            case ClangLiteralScanner.quote:
                index = ClangLiteralScanner.anyStringLiteral(openingQuoteAt: index, in: bytes).next
            case ClangLiteralScanner.apostrophe:
                index = ClangLiteralScanner.endOfCharacterLiteral(from: index + 1, in: bytes)
            case ClangLiteralScanner.at where bytes[index...].starts(with: keyword):
                if let (path, end) = modulePath(from: index + keyword.count, in: bytes) {
                    let location = location(of: index, in: bytes, splices: splices, file: file)
                    statements.append(ImportStatement(
                        module: path.first ?? "",
                        qualifiedModule: path.joined(separator: "."),
                        isTestable: false,
                        isExported: false,
                        isConditional: conditionalDepth > 0,
                        location: location,
                        commentCommands: commentCommands(forStatementAt: index, endingBefore: end, in: bytes)
                    ))
                    index = end
                } else {
                    index += keyword.count
                }
            default:
                index += 1
            }
        }

        return statements
    }

    // MARK: - Private

    /// The slice as text; a slice that is not UTF-8 is empty, so it names no module and holds no command.
    private static func text(_ slice: ArraySlice<UInt8>) -> String {
        String(bytes: slice, encoding: .utf8) ?? ""
    }

    /// The lowercase name after the `#` at `index`, such as `ifdef`, or an empty string.
    private static func directiveName(after index: Int, in bytes: [UInt8]) -> String {
        var cursor = index + 1
        while cursor < bytes.count, ClangLiteralScanner.isBlank(bytes[cursor]) {
            cursor += 1
        }

        let start = cursor
        while cursor < bytes.count, bytes[cursor] >= UInt8(ascii: "a"), bytes[cursor] <= UInt8(ascii: "z") {
            cursor += 1
        }

        return text(bytes[start ..< cursor])
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
    /// spliced out, so they match the file as the editor and the index show it.
    private static func location(of index: Int, in bytes: [UInt8], splices: [Int], file: SourceFile) -> Location {
        var line = 1 + splices.prefix(while: { $0 <= index }).count
        var lineStart = 0
        for position in 0 ..< index where bytes[position] == ClangLiteralScanner.newline {
            line += 1
            lineStart = position + 1
        }
        return Location(file: file, line: line, column: index - lineStart + 1)
    }

    /// The commands in comments that trail the statement on its line, and in a comment-only line
    /// directly above it, as Swift's leading and trailing trivia are read.
    private static func commentCommands(forStatementAt index: Int, endingBefore end: Int, in bytes: [UInt8]) -> [CommentCommand] {
        var comments: [String] = []

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
        if lineStart > 0 {
            let previousEnd = lineStart - 1
            let previousStart = (bytes[..<previousEnd].lastIndex(of: ClangLiteralScanner.newline) ?? -1) + 1
            let previous = text(bytes[previousStart ..< previousEnd])
                .trimmingCharacters(in: .whitespaces)
            if previous.hasPrefix("//") || previous.hasPrefix("/*") {
                comments.append(previous)
            }
        }

        return comments.compactMap { CommentCommand.parseCommand(inComment: $0) }
    }
}

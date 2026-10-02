import Foundation
import SyntaxAnalysis

/// Finds the names a C or Objective-C file spells as strings: the contents of every string literal
/// (`@"handleTap:"` and `"Module.Name"` alike) and of every `@selector(...)`. Like Swift string
/// literals, they can name a declaration for a runtime lookup (`NSSelectorFromString`,
/// `NSClassFromString`, key-value coding) that the index cannot show as a reference.
///
/// A single pass over the bytes that skips comments, character literals, and `#import` and `#include`
/// lines, whose quoted file names are not symbol names. Only literals shaped like a symbol reference
/// count, as in `StringLiteralTokenVisitor`. It does not expand macros or follow `#if`, so a literal
/// in any branch counts.
enum ClangLiteralScanner {
    private static let newline = UInt8(ascii: "\n")
    private static let slash = UInt8(ascii: "/")
    private static let star = UInt8(ascii: "*")
    private static let quote = UInt8(ascii: "\"")
    private static let apostrophe = UInt8(ascii: "'")
    private static let backslash = UInt8(ascii: "\\")
    private static let hash = UInt8(ascii: "#")
    private static let at = UInt8(ascii: "@")
    private static let openParen = UInt8(ascii: "(")
    private static let closeParen = UInt8(ascii: ")")
    private static let selectorKeyword = Array("@selector".utf8)

    /// Scans the file's bytes, so a byte that is not UTF-8 in a comment or a prose string costs only
    /// that literal, never the rest of the file.
    static func tokens(in bytes: [UInt8]) -> Set<String> {
        var tokens: Set<String> = []
        var index = 0
        var atLineStart = true

        func add(_ literal: [UInt8]) {
            guard let text = String(bytes: literal, encoding: .utf8),
                  let identifiers = StringLiteralTokenVisitor.symbolIdentifiers(in: text)
            else { return }

            tokens.formUnion(identifiers)
        }

        while index < bytes.count {
            let byte = bytes[index]
            let wasAtLineStart = atLineStart
            atLineStart = byte == newline || (wasAtLineStart && isBlank(byte))

            switch byte {
            case hash where wasAtLineStart:
                // Other directives, such as a `#define` of a selector string, are scanned as code.
                index = isIncludeDirective(at: index, in: bytes) ? endOfLine(from: index, in: bytes) : index + 1
            case slash where bytes[safe: index + 1] == slash:
                index = endOfLine(from: index, in: bytes)
            case slash where bytes[safe: index + 1] == star:
                index = endOfBlockComment(from: index + 2, in: bytes)
            case quote:
                let (literal, next) = stringLiteral(from: index + 1, in: bytes)
                add(literal)
                index = next
            case apostrophe:
                index = endOfCharacterLiteral(from: index + 1, in: bytes)
            case at where bytes[index...].starts(with: selectorKeyword):
                let (selector, next) = selectorName(from: index + selectorKeyword.count, in: bytes)
                if let selector {
                    add(selector)
                }
                index = next
            default:
                index += 1
            }
        }

        return tokens
    }

    // MARK: - Private

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    private static func endOfLine(from index: Int, in bytes: [UInt8]) -> Int {
        bytes[index...].firstIndex(of: newline) ?? bytes.count
    }

    /// The index after the closing `*/`, or the end of the file when the comment is unterminated.
    private static func endOfBlockComment(from index: Int, in bytes: [UInt8]) -> Int {
        var cursor = index
        while cursor + 1 < bytes.count {
            if bytes[cursor] == star, bytes[cursor + 1] == slash { return cursor + 2 }

            cursor += 1
        }

        return bytes.count
    }

    /// Whether the directive after the `#` at `index` is `import` or `include`.
    private static func isIncludeDirective(at index: Int, in bytes: [UInt8]) -> Bool {
        var cursor = index + 1
        while cursor < bytes.count, isBlank(bytes[cursor]) {
            cursor += 1
        }

        let start = cursor
        while cursor < bytes.count, bytes[cursor] >= UInt8(ascii: "a"), bytes[cursor] <= UInt8(ascii: "z") {
            cursor += 1
        }

        let name = String(bytes: bytes[start ..< cursor], encoding: .utf8)
        return ["import", "include", "include_next"].contains(name)
    }

    /// The text of a string literal whose opening quote precedes `index`, and the index after it. An
    /// escaped quote is kept as a quote, which makes the text prose rather than a name. A literal that
    /// reaches the end of its line unclosed ends there.
    private static func stringLiteral(from index: Int, in bytes: [UInt8]) -> (text: [UInt8], next: Int) {
        var text: [UInt8] = []
        var cursor = index

        while cursor < bytes.count, bytes[cursor] != newline {
            let byte = bytes[cursor]
            if byte == quote { return (text, cursor + 1) }

            if byte == backslash, let escaped = bytes[safe: cursor + 1], escaped != newline {
                text.append(escaped == quote ? quote : byte)
                if escaped != quote { text.append(escaped) }
                cursor += 2
                continue
            }

            text.append(byte)
            cursor += 1
        }

        return (text, cursor)
    }

    /// The index after a character literal whose opening apostrophe precedes `index`, so that `'"'`
    /// does not open a string.
    private static func endOfCharacterLiteral(from index: Int, in bytes: [UInt8]) -> Int {
        var cursor = index
        while cursor < bytes.count, bytes[cursor] != newline {
            if bytes[cursor] == backslash {
                cursor += 2
                continue
            }

            if bytes[cursor] == apostrophe { return cursor + 1 }

            cursor += 1
        }

        return min(cursor, bytes.count)
    }

    /// The selector in the parentheses after `@selector`, without whitespace, and the index after it.
    /// `nil` when no parenthesis follows. A selector that reaches the end of its line unclosed ends there.
    private static func selectorName(from index: Int, in bytes: [UInt8]) -> (name: [UInt8]?, next: Int) {
        var cursor = index
        while cursor < bytes.count, isBlank(bytes[cursor]) {
            cursor += 1
        }

        guard bytes[safe: cursor] == openParen else { return (nil, cursor) }

        var name: [UInt8] = []
        cursor += 1
        while cursor < bytes.count, bytes[cursor] != closeParen, bytes[cursor] != newline {
            if !isBlank(bytes[cursor]) { name.append(bytes[cursor]) }

            cursor += 1
        }

        return (name, cursor)
    }
}

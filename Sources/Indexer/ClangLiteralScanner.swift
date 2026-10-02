import Foundation
import SyntaxAnalysis
import SystemPackage

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

    /// The tokens of every file that can be read, and the files that cannot: a file compiled into the
    /// index but gone or unreadable since may spell a lookup the scan then cannot see.
    static func scan(files: [FilePath]) -> (tokens: Set<String>, unreadFiles: [FilePath]) {
        var tokens: Set<String> = []
        var unreadFiles: [FilePath] = []
        for file in files {
            if let data = FileManager.default.contents(atPath: file.string) {
                tokens.formUnion(self.tokens(in: Array(data)))
            } else {
                unreadFiles.append(file)
            }
        }
        return (tokens, unreadFiles)
    }

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
                // Adjacent literals (`@"Renamed" @"Class"`) are one string to the compiler.
                var (literal, next) = stringLiteral(from: index + 1, in: bytes)
                while let continuation = adjacentLiteralStart(from: next, in: bytes) {
                    let (more, after) = stringLiteral(from: continuation, in: bytes)
                    literal += more
                    next = after
                }
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

    /// The index after the opening quote of a string literal that directly follows the one ending before
    /// `index`, with only whitespace and an optional `@` between them, or `nil`.
    private static func adjacentLiteralStart(from index: Int, in bytes: [UInt8]) -> Int? {
        var cursor = index
        while cursor < bytes.count, isBlank(bytes[cursor]) || bytes[cursor] == newline {
            cursor += 1
        }

        if bytes[safe: cursor] == at { cursor += 1 }

        return bytes[safe: cursor] == quote ? cursor + 1 : nil
    }

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

    /// The value of a string literal whose opening quote precedes `index`, and the index after it. C
    /// escapes are decoded as the compiler decodes them, so `"f\x6fo"` is `foo`; an escaped quote
    /// becomes a quote, which makes the text prose rather than a name. A literal that reaches the end of
    /// its line unclosed ends there.
    private static func stringLiteral(from index: Int, in bytes: [UInt8]) -> (text: [UInt8], next: Int) {
        var text: [UInt8] = []
        var cursor = index

        while cursor < bytes.count, bytes[cursor] != newline {
            let byte = bytes[cursor]
            if byte == quote { return (text, cursor + 1) }

            if byte == backslash, let escaped = bytes[safe: cursor + 1], escaped != newline {
                let (value, next) = escapeSequence(at: cursor + 1, in: bytes)
                text += value
                cursor = next
                continue
            }

            text.append(byte)
            cursor += 1
        }

        return (text, cursor)
    }

    private static let simpleEscapes: [UInt8: UInt8] = [
        UInt8(ascii: "n"): UInt8(ascii: "\n"), UInt8(ascii: "t"): UInt8(ascii: "\t"), UInt8(ascii: "r"): UInt8(ascii: "\r"),
        UInt8(ascii: "0"): 0, UInt8(ascii: "a"): 7, UInt8(ascii: "b"): 8, UInt8(ascii: "f"): 12, UInt8(ascii: "v"): 11,
        UInt8(ascii: "e"): 27, UInt8(ascii: "?"): UInt8(ascii: "?"),
        quote: quote, apostrophe: apostrophe, backslash: backslash,
    ]

    /// The bytes an escape sequence starting after the backslash at `index` stands for, and the index
    /// after it: a simple escape (`\n`, `\"`), hex (`\x6f`), octal (`\146`), or a code point (`\u00e9`,
    /// `\U0001F600`) as UTF-8. An escape the compiler would reject stands for itself.
    private static func escapeSequence(at index: Int, in bytes: [UInt8]) -> (value: [UInt8], next: Int) {
        let escaped = bytes[index]

        if escaped == UInt8(ascii: "x") {
            let (digits, next) = digits(from: index + 1, in: bytes, radix: 16, maximum: Int.max)
            guard !digits.isEmpty, let value = UInt32(digits, radix: 16), value <= 0xFF else { return ([backslash, escaped], index + 1) }

            return ([UInt8(value)], next)
        }

        if escaped == UInt8(ascii: "u") || escaped == UInt8(ascii: "U") {
            let length = escaped == UInt8(ascii: "u") ? 4 : 8
            let (digits, next) = digits(from: index + 1, in: bytes, radix: 16, maximum: length)
            guard digits.count == length, let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else {
                return ([backslash, escaped], index + 1)
            }

            return (Array(String(Character(scalar)).utf8), next)
        }

        if isOctalDigit(escaped) {
            let (digits, next) = digits(from: index, in: bytes, radix: 8, maximum: 3)
            guard let value = UInt32(digits, radix: 8), value <= 0xFF else { return ([backslash, escaped], index + 1) }

            return ([UInt8(value)], next)
        }

        if let value = simpleEscapes[escaped] {
            return ([value], index + 1)
        }

        return ([backslash, escaped], index + 1)
    }

    private static func isOctalDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "7")
    }

    /// Up to `maximum` digits of the radix starting at `index`, and the index after them.
    private static func digits(from index: Int, in bytes: [UInt8], radix: Int, maximum: Int) -> (digits: String, next: Int) {
        var cursor = index
        var digits = ""
        while cursor < bytes.count, digits.count < maximum, let scalar = Unicode.Scalar(UInt32(bytes[cursor])),
              Character(scalar).hexDigitValue.map({ $0 < radix }) == true
        {
            digits.append(Character(scalar))
            cursor += 1
        }
        return (digits, cursor)
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

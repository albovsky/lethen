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
    static let newline = UInt8(ascii: "\n")
    static let slash = UInt8(ascii: "/")
    static let star = UInt8(ascii: "*")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")
    static let backslash = UInt8(ascii: "\\")
    static let hash = UInt8(ascii: "#")
    static let at = UInt8(ascii: "@")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    private static let selectorKeyword = Array("@selector".utf8)

    /// The tokens of every file that can be read, and the files that cannot: a file compiled into the
    /// index but gone or unreadable since may spell a lookup the scan then cannot see. `visit` receives
    /// each file's bytes, so a caller that scans the same files for something else reads them once.
    static func scan(
        files: [FilePath],
        visiting visit: (FilePath, [UInt8]) -> Void = { _, _ in }
    ) -> (tokens: Set<String>, unreadFiles: [FilePath]) {
        var tokens: Set<String> = []
        var unreadFiles: [FilePath] = []
        for file in files {
            if let data = FileManager.default.contents(atPath: file.string) {
                let bytes = Array(data)
                tokens.formUnion(self.tokens(in: bytes))
                visit(file, bytes)
            } else {
                unreadFiles.append(file)
            }
        }
        return (tokens, unreadFiles)
    }

    /// Scans the file's bytes, so a byte that is not UTF-8 in a comment or a prose string costs only
    /// that literal, never the rest of the file.
    static func tokens(in source: [UInt8]) -> Set<String> {
        // The preprocessor removes every backslash-newline pair before it sees tokens.
        let bytes = splicingLines(source).bytes
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
                // Adjacent literals (`@"Renamed" @"Class"`, `R"(renamed)" "ForObjC"`) are one string to the compiler.
                var (literal, next) = anyStringLiteral(openingQuoteAt: index, in: bytes)
                while let continuation = adjacentLiteralQuote(from: next, in: bytes) {
                    let (more, after) = anyStringLiteral(openingQuoteAt: continuation, in: bytes)
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

    /// The bytes with every backslash-newline pair removed, as the preprocessor splices lines, and the
    /// index in the result at which each removed pair stood, so a caller can still number the lines
    /// of the original file.
    static func splicingLines(_ bytes: [UInt8]) -> (bytes: [UInt8], splices: [Int]) {
        guard bytes.contains(backslash) else { return (bytes, []) }

        var result: [UInt8] = []
        var splices: [Int] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if bytes[index] == backslash {
                if bytes[safe: index + 1] == newline {
                    splices.append(result.count)
                    index += 2
                    continue
                }
                if bytes[safe: index + 1] == UInt8(ascii: "\r"), bytes[safe: index + 2] == newline {
                    splices.append(result.count)
                    index += 3
                    continue
                }
            }
            result.append(bytes[index])
            index += 1
        }
        return (result, splices)
    }

    /// The index of the first byte after `index` that is not whitespace or a comment, which the
    /// preprocessor turns into whitespace.
    static func skippingBlanksAndComments(from index: Int, in bytes: [UInt8]) -> Int {
        var cursor = index
        while cursor < bytes.count {
            if isBlank(bytes[cursor]) || bytes[cursor] == newline {
                cursor += 1
            } else if bytes[cursor] == slash, bytes[safe: cursor + 1] == slash {
                cursor = endOfLine(from: cursor, in: bytes)
            } else if bytes[cursor] == slash, bytes[safe: cursor + 1] == star {
                cursor = endOfBlockComment(from: cursor + 2, in: bytes)
            } else {
                break
            }
        }
        return cursor
    }

    /// The index of the opening quote of a string literal that directly follows the one ending before
    /// `index`, with only whitespace, comments, an optional `@`, and an optional raw-string prefix between
    /// them, or `nil`.
    static func adjacentLiteralQuote(from index: Int, in bytes: [UInt8]) -> Int? {
        var cursor = skippingBlanksAndComments(from: index, in: bytes)
        if bytes[safe: cursor] == at { cursor += 1 }

        // A raw string's prefix (`R`, `LR`, `u8R`) stands between the whitespace and the quote.
        for length in [0, 1, 2, 3] where bytes[safe: cursor + length] == quote {
            let quoteIndex = cursor + length
            return length == 0 || rawStringDelimiter(before: quoteIndex, in: bytes) != nil ? quoteIndex : nil
        }

        return nil
    }

    /// The text of the string literal whose opening quote is at `index`, raw or ordinary, and the
    /// index after it. A C++ raw string (`R"(name)"`, `R"x(name)x"`) has no escapes and may span lines.
    static func anyStringLiteral(openingQuoteAt index: Int, in bytes: [UInt8]) -> (text: [UInt8], next: Int) {
        if let delimiter = rawStringDelimiter(before: index, in: bytes) {
            return rawStringLiteral(from: index + 1, delimiter: delimiter, in: bytes)
        }

        return stringLiteral(from: index + 1, in: bytes)
    }

    static func isBlank(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    static func endOfLine(from index: Int, in bytes: [UInt8]) -> Int {
        bytes[index...].firstIndex(of: newline) ?? bytes.count
    }

    /// The index after the closing `*/`, or the end of the file when the comment is unterminated.
    static func endOfBlockComment(from index: Int, in bytes: [UInt8]) -> Int {
        var cursor = index
        while cursor + 1 < bytes.count {
            if bytes[cursor] == star, bytes[cursor + 1] == slash { return cursor + 2 }

            cursor += 1
        }

        return bytes.count
    }

    /// Whether the directive after the `#` at `index` is `import` or `include`.
    static func isIncludeDirective(at index: Int, in bytes: [UInt8]) -> Bool {
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
    static func endOfCharacterLiteral(from index: Int, in bytes: [UInt8]) -> Int {
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
        var cursor = skippingBlanksAndComments(from: index, in: bytes)
        guard bytes[safe: cursor] == openParen else { return (nil, cursor) }

        var name: [UInt8] = []
        cursor += 1
        while cursor < bytes.count, bytes[cursor] != closeParen {
            if bytes[cursor] == slash, bytes[safe: cursor + 1] == slash || bytes[safe: cursor + 1] == star {
                cursor = skippingBlanksAndComments(from: cursor, in: bytes)
                continue
            }
            if bytes[cursor] == newline {
                // A selector broken across lines is still one selector; a blank line means it was never closed.
                if bytes[safe: cursor + 1] == newline { break }

                cursor += 1
                continue
            }

            if !isBlank(bytes[cursor]) { name.append(bytes[cursor]) }
            cursor += 1
        }

        return (name, cursor)
    }

    /// The delimiter of a C++ raw string whose opening quote is at `index` (`R"`, `LR"`, `u8R"`, `uR"`,
    /// `UR"`), or `nil` when the quote opens an ordinary string. The delimiter is what stands between the
    /// quote and the opening parenthesis, up to 16 bytes.
    private static func rawStringDelimiter(before index: Int, in bytes: [UInt8]) -> [UInt8]? {
        guard index > 0, bytes[index - 1] == UInt8(ascii: "R") else { return nil }

        let prefixEnd = index - 1
        let prefixStart = max(0, prefixEnd - 2)
        let prefix = Array(bytes[prefixStart ..< prefixEnd])
        let before = prefixStart > 0 ? bytes[prefixStart - 1] : nil
        let validPrefixes: [[UInt8]] = [[], Array("L".utf8), Array("u".utf8), Array("U".utf8), Array("u8".utf8)]
        let hasValidPrefix = validPrefixes.contains { candidate in
            prefix.suffix(candidate.count).elementsEqual(candidate)
                && !isIdentifierByte(prefix.dropLast(candidate.count).last ?? before ?? UInt8(ascii: " "))
        }
        guard hasValidPrefix else { return nil }

        var cursor = index + 1
        var delimiter: [UInt8] = []
        while cursor < bytes.count, bytes[cursor] != openParen, delimiter.count <= 16 {
            guard !isBlank(bytes[cursor]), bytes[cursor] != newline, bytes[cursor] != backslash, bytes[cursor] != quote else { return nil }

            delimiter.append(bytes[cursor])
            cursor += 1
        }

        return bytes[safe: cursor] == openParen ? delimiter : nil
    }

    /// The text of a raw string whose opening quote precedes `index`, and the index after its closing
    /// `)delimiter"`, or the end of the file when it never closes.
    private static func rawStringLiteral(from index: Int, delimiter: [UInt8], in bytes: [UInt8]) -> (text: [UInt8], next: Int) {
        let start = index + delimiter.count + 1
        let terminator = [closeParen] + delimiter + [quote]
        var cursor = start
        while cursor + terminator.count <= bytes.count {
            if bytes[cursor ..< cursor + terminator.count].elementsEqual(terminator) {
                return (Array(bytes[start ..< cursor]), cursor + terminator.count)
            }
            cursor += 1
        }
        return (Array(bytes[min(start, bytes.count)...]), bytes.count)
    }

    static func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) || byte == UInt8(ascii: "_")
    }
}

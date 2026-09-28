import SwiftSyntax

/// Collects the identifiers of every string literal shaped like a symbol reference: a selector
/// (`"handleTap:"`), a qualified name (`"Module.ClassName"`), a key path (`"user.name"`), or a bare
/// identifier. A declaration with such a name may be looked up dynamically (`NSSelectorFromString`,
/// `NSClassFromString`, key-value coding), which lowers Lethen's confidence that it is unused.
/// Literals with spaces or interpolation are prose, such as log messages, and are skipped.
public final class StringLiteralTokenVisitor: SyntaxVisitor {
    public private(set) var tokens: Set<String> = []

    public init() {
        super.init(viewMode: .sourceAccurate)
    }

    override public func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        var text = ""
        for segment in node.segments {
            guard case let .stringSegment(segment) = segment else { return .visitChildren }

            text += segment.content.text
        }
        if let identifiers = Self.symbolIdentifiers(in: text) {
            tokens.formUnion(identifiers)
        }
        return .visitChildren
    }

    /// The identifiers of a symbol-shaped string, or nil when the string is not one.
    static func symbolIdentifiers(in text: String) -> [String]? {
        var identifiers: [String] = []
        var current = ""

        for character in text {
            if character.isLetter || character == "_" || (!current.isEmpty && character.isNumber) {
                current.append(character)
            } else if character == "." || character == ":", !current.isEmpty {
                identifiers.append(current)
                current = ""
            } else {
                return nil
            }
        }
        if !current.isEmpty {
            identifiers.append(current)
        }
        return identifiers.isEmpty ? nil : identifiers
    }
}

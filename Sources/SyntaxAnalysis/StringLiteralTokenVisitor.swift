import SwiftSyntax

/// Collects the identifier-like words of every string literal in a file. A declaration whose name
/// is such a word may be looked up dynamically (selectors, `NSClassFromString`, key paths in
/// strings), which lowers Lethen's confidence that it is unused.
public final class StringLiteralTokenVisitor: SyntaxVisitor {
    public private(set) var tokens: Set<String> = []

    public init() {
        super.init(viewMode: .sourceAccurate)
    }

    override public func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        for segment in node.segments {
            guard case let .stringSegment(text) = segment else { continue }

            tokens.formUnion(Self.identifiers(in: text.content.text))
        }
        return .visitChildren
    }

    static func identifiers(in text: String) -> [String] {
        var identifiers: [String] = []
        var current = ""

        for character in text {
            let isStart = character.isLetter || character == "_"
            if isStart || (!current.isEmpty && character.isNumber) {
                current.append(character)
            } else if !current.isEmpty {
                identifiers.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            identifiers.append(current)
        }
        return identifiers
    }
}

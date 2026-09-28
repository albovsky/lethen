import SwiftSyntax

/// Finds enum case references that appear inside patterns, where they match a value rather than
/// construct one.
public final class EnumCasePatternSyntaxVisitor: SyntaxVisitor {
    /// Positions of the member name in each pattern, for the indexer to map to references.
    public private(set) var memberPositions: [AbsolutePosition] = []
    /// Member names, for tests.
    public private(set) var memberNames: [String] = []

    public init() {
        super.init(viewMode: .sourceAccurate)
    }

    override public func visit(_ node: ExpressionPatternSyntax) -> SyntaxVisitorContinueKind {
        for member in MemberAccessCollector.members(in: node.expression) {
            memberPositions.append(member.declName.baseName.positionAfterSkippingLeadingTrivia)
            memberNames.append(member.declName.baseName.text)
        }
        return .skipChildren
    }

    private final class MemberAccessCollector: SyntaxVisitor {
        private var members: [MemberAccessExprSyntax] = []

        static func members(in expression: ExprSyntax) -> [MemberAccessExprSyntax] {
            let collector = MemberAccessCollector(viewMode: .sourceAccurate)
            collector.walk(expression)
            return collector.members
        }

        override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
            members.append(node)
            return .visitChildren
        }
    }
}

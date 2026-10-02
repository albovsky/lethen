import SourceGraph
import SwiftSyntax

/// Collects the names used inside `#if` clauses that the build did not compile.
///
/// The compiler records nothing for a branch it skips, so a declaration used only there is
/// reported as unused even though another platform or configuration would use it. Which clause was
/// compiled is read from the index, not from the condition: a clause is taken when `evidence`, the
/// locations of the file's indexed declarations and references, has an entry inside it, and skipped
/// when it has none although it contains syntax the index would have recorded. A clause with
/// nothing but imports or comments leaves no evidence either way and is ignored. Only uses count: the
/// names of declarations written in the clause, labels, parameters, import paths, and enum case
/// patterns do not.
public final class SkippedConditionalBranchVisitor: SyntaxVisitor {
    /// Each used name mapped to the lexicographically smallest description of a skipped clause
    /// that uses it, such as `#if os(Windows) at File.swift:12`.
    public private(set) var names: [String: String] = [:]

    /// The subset of `names` with a use spelled as a member access or a call.
    public private(set) var memberNames: [String: String] = [:]

    private let locationBuilder: SourceLocationBuilder
    private let evidence: Set<Location>

    public init(locationBuilder: SourceLocationBuilder, evidence: Set<Location>) {
        self.locationBuilder = locationBuilder
        self.evidence = evidence
        super.init(viewMode: .sourceAccurate)
    }

    override public func visit(_ node: IfConfigDeclSyntax) -> SyntaxVisitorContinueKind {
        for clause in node.clauses {
            guard let elements = clause.elements else { continue }

            let start = locationBuilder.location(at: elements.positionAfterSkippingLeadingTrivia)
            let end = locationBuilder.location(at: elements.endPositionBeforeTrailingTrivia)
            let isTaken = evidence.contains { start <= $0 && $0 <= end }
            guard !isTaken else { continue }

            let content = ClauseContent(Syntax(elements))
            guard content.hasIndexableSyntax else { continue }

            let keyword = clause.poundKeyword.text
            let condition = clause.condition.map { " " + $0.trimmedDescription } ?? ""
            let line = locationBuilder.location(at: clause.positionAfterSkippingLeadingTrivia).line
            let file = start.file.path.lastComponent?.string ?? start.file.path.string
            let site = "\(keyword)\(condition) at \(file):\(line)"
            for (identifier, isMember) in content.uses {
                if names[identifier].map({ $0 > site }) ?? true { names[identifier] = site }
                if isMember, memberNames[identifier].map({ $0 > site }) ?? true { memberNames[identifier] = site }
            }
        }
        return .visitChildren
    }

    private struct ClauseContent {
        /// Names used in the clause, each flagged when some use is a member access or a call.
        var uses: [String: Bool] = [:]
        var hasIndexableSyntax = false

        init(_ node: Syntax) {
            collect(node)
        }

        private mutating func collect(_ node: Syntax) {
            if node.is(ImportDeclSyntax.self) { return }

            // Any other declaration, call, or reference is recorded by the index.
            if node.is(DeclSyntax.self) || node.is(FunctionCallExprSyntax.self)
                || node.is(MemberAccessExprSyntax.self) || node.is(DeclReferenceExprSyntax.self)
            {
                hasIndexableSyntax = true
            }
            // Matching an enum case is not constructing it, so a pattern is no use of the name.
            if let item = node.as(SwitchCaseItemSyntax.self) {
                if let clause = item.whereClause { collect(Syntax(clause)) }
                return
            }
            if let condition = node.as(MatchingPatternConditionSyntax.self) {
                collect(Syntax(condition.initializer))
                return
            }
            if let reference = node.as(DeclReferenceExprSyntax.self) {
                let name = reference.baseName.identifier?.name ?? reference.baseName.text
                let isMember = reference.parent?.as(MemberAccessExprSyntax.self)?.declName.id == reference.id
                    || reference.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id == reference.id
                uses[name] = (uses[name] ?? false) || isMember
            } else if let type = node.as(IdentifierTypeSyntax.self) {
                let name = type.name.identifier?.name ?? type.name.text
                uses[name] = uses[name] ?? false
            } else if let type = node.as(MemberTypeSyntax.self) {
                uses[type.name.identifier?.name ?? type.name.text] = true
            }
            for child in node.children(viewMode: .sourceAccurate) {
                collect(child)
            }
        }
    }
}

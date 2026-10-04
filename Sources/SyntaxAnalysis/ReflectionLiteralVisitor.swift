import SourceGraph
import SwiftSyntax

/// Collects the identifiers of string literals that the runtime can resolve to a declaration: the
/// argument of a reflection or dynamic-lookup API, or a label compared against a `Mirror` child.
///
/// A bare literal naming a pure-Swift declaration, such as a log message or a coding key, is not
/// collected: only these call sites can turn a string into a Swift class, property or function.
public final class ReflectionLiteralVisitor: SyntaxVisitor {
    /// Each identifier mapped to the lexicographically smallest description of a call site that
    /// passes it, such as `NSClassFromString at File.swift:12`.
    public private(set) var sites: [String: String] = [:]

    private let locationBuilder: SourceLocationBuilder

    /// Calls whose every string literal argument names a symbol.
    private static let namingCalls: Set<String> = ["NSClassFromString", "NSSelectorFromString", "Selector", "classNamed"]
    /// Argument labels that name a symbol whatever the call: `value(forKey:)`, `setValue(_:forKeyPath:)`,
    /// `instantiateViewController(withIdentifier:)`, `UINib(nibName:)`.
    private static let namingLabels: Set<String> = ["forKey", "forKeyPath", "withIdentifier", "nibName"]

    public init(locationBuilder: SourceLocationBuilder) {
        self.locationBuilder = locationBuilder
        super.init(viewMode: .sourceAccurate)
    }

    override public func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let callee = Self.calleeName(of: node.calledExpression)
        for argument in node.arguments {
            guard let literal = argument.expression.as(StringLiteralExprSyntax.self) else { continue }

            if let callee, Self.namingCalls.contains(callee) {
                record(literal, kind: callee)
            } else if let label = argument.label?.text, Self.namingLabels.contains(label) {
                record(literal, kind: "\(callee ?? "a call")(\(label):)")
            }
        }
        return .visitChildren
    }

    /// `child.label == "name"`, the way a `Mirror` walk finds a property by its name. The tree is not folded,
    /// so the comparison is a flat sequence of operands and operators.
    override public func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for (index, element) in elements.enumerated() {
            guard let comparison = element.as(BinaryOperatorExprSyntax.self)?.operator.text, comparison == "==" || comparison == "!=",
                  index > 0, index + 1 < elements.count
            else { continue }

            for (label, literal) in [(elements[index - 1], elements[index + 1]), (elements[index + 1], elements[index - 1])] {
                if let access = label.as(MemberAccessExprSyntax.self), access.declName.baseName.text == "label",
                   let literal = literal.as(StringLiteralExprSyntax.self)
                {
                    record(literal, kind: "a Mirror label comparison")
                }
            }
        }
        return .visitChildren
    }

    private static func calleeName(of expression: ExprSyntax) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName.text }
        return expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }

    private func record(_ literal: StringLiteralExprSyntax, kind: String) {
        var text = ""
        for segment in literal.segments {
            guard case let .stringSegment(segment) = segment else { return }

            text += segment.content.text
        }
        guard let identifiers = StringLiteralTokenVisitor.symbolIdentifiers(in: text) else { return }

        let location = locationBuilder.location(at: literal.positionAfterSkippingLeadingTrivia)
        let file = location.file.path.lastComponent?.string ?? location.file.path.string
        let site = "\(kind) at \(file):\(location.line)"
        for identifier in identifiers where sites[identifier].map({ $0 > site }) ?? true {
            sites[identifier] = site
        }
    }
}

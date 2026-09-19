import SourceGraph
import SwiftSyntax

/// Associates call operands with the indexed expressions that supplied their values.
/// Local variables are absent from the index, so resolve their lexical bindings here.
public final class ValueUseSyntaxVisitor: SyntaxVisitor {
    public private(set) var arguments: [Location: Set<Location>] = [:]
    public private(set) var genericTypeLocations: Set<Location> = []
    private var genericNames: [Set<String>] = [[]]
    private let locations: SourceLocationBuilder
    private var scopes: [[String: Set<Location>]] = [[:]]

    public init(locations: SourceLocationBuilder) {
        self.locations = locations
        super.init(viewMode: .sourceAccurate)
    }

    override public func visit(_: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        scopes.append([:])
        return .visitChildren
    }

    override public func visitPost(_: CodeBlockSyntax) {
        scopes.removeLast()
    }

    override public func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        scopes.append([:])
        if let parameters = node.signature?.parameterClause?.as(ClosureParameterClauseSyntax.self) {
            for parameter in parameters.parameters {
                let name = parameter.secondName ?? parameter.firstName
                scopes[scopes.count - 1][name.text] = parameter.type.map { tokens(in: $0) } ?? []
            }
        }
        return .visitChildren
    }

    override public func visitPost(_: ClosureExprSyntax) {
        scopes.removeLast()
    }

    override public func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        scopes.append([:])
        genericNames.append((genericNames.last ?? []).union(node.genericParameterClause?.parameters.map(\.name.text) ?? []))
        for parameter in node.signature.parameterClause.parameters {
            let name = parameter.secondName ?? parameter.firstName
            scopes[scopes.count - 1][name.text] = tokens(in: parameter.type)
        }
        return .visitChildren
    }

    override public func visitPost(_: FunctionDeclSyntax) {
        scopes.removeLast()
        genericNames.removeLast()
    }

    override public func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }

            let annotation = binding.typeAnnotation.map { tokens(in: $0.type) } ?? []
            let initial = binding.initializer.map { origins(of: $0.value) } ?? []
            scopes[scopes.count - 1][identifier.identifier.text] = annotation.union(initial)
        }
        return .visitChildren
    }

    override public func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        var values = node.arguments.reduce(into: Set<Location>()) { $0.formUnion(origins(of: $1.expression)) }
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base {
            values.formUnion(origins(of: base))
        }
        arguments[calleeLocation(node.calledExpression), default: []].formUnion(values)
        return .visitChildren
    }

    override public func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Dictionary keys are passed to a subscript's hashing/equality operations.
        // The collection itself is not a compared value (e.g. array[0].field).
        let values = node.arguments.reduce(into: Set<Location>()) { $0.formUnion(origins(of: $1.expression)) }
        arguments[locations.location(at: node.leftSquare.positionAfterSkippingLeadingTrivia), default: []].formUnion(values)
        return .visitChildren
    }

    override public func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        let elements = Array(node.elements)
        for index in elements.indices where index > 0 && index + 1 < elements.count {
            guard let operation = elements[index].as(BinaryOperatorExprSyntax.self) else { continue }

            arguments[locations.location(at: operation.operator.positionAfterSkippingLeadingTrivia), default: []]
                .formUnion(origins(of: elements[index - 1]).union(origins(of: elements[index + 1])))
        }
        return .visitChildren
    }

    private func origins(of expression: ExprSyntax) -> Set<Location> {
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            for scope in scopes.reversed() {
                if let bound = scope[reference.baseName.text] {
                    return bound
                }
            }
            return [locations.location(at: reference.baseName.positionAfterSkippingLeadingTrivia)]
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return [calleeLocation(call.calledExpression)]
        }
        if let member = expression.as(MemberAccessExprSyntax.self) {
            // Passing value.field passes the field, not the containing value.
            return [locations.location(at: member.declName.baseName.positionAfterSkippingLeadingTrivia)]
        }
        if let array = expression.as(ArrayExprSyntax.self) {
            return array.elements.reduce(into: []) { $0.formUnion(origins(of: $1.expression)) }
        }
        if let tuple = expression.as(TupleExprSyntax.self) {
            return tuple.elements.reduce(into: []) { $0.formUnion(origins(of: $1.expression)) }
        }
        if let optional = expression.as(OptionalChainingExprSyntax.self) {
            return origins(of: optional.expression)
        }
        if let forced = expression.as(ForceUnwrapExprSyntax.self) {
            return origins(of: forced.expression)
        }
        if let awaited = expression.as(AwaitExprSyntax.self) {
            return origins(of: awaited.expression)
        }
        if let tried = expression.as(TryExprSyntax.self) {
            return origins(of: tried.expression)
        }
        return []
    }

    private func calleeLocation(_ expression: ExprSyntax) -> Location {
        if let member = expression.as(MemberAccessExprSyntax.self) {
            return locations.location(at: member.declName.baseName.positionAfterSkippingLeadingTrivia)
        }
        if let specialized = expression.as(GenericSpecializationExprSyntax.self) {
            return calleeLocation(specialized.expression)
        }
        return locations.location(at: expression.positionAfterSkippingLeadingTrivia)
    }

    private func tokens(in syntax: TypeSyntax) -> Set<Location> {
        let tokens = TypeSyntaxInspector(sourceLocationBuilder: locations).types(for: syntax)
        for token in tokens where genericNames.last?.contains(token.text) == true {
            genericTypeLocations.insert(locations.location(at: token.positionAfterSkippingLeadingTrivia))
        }
        return Set(tokens.map { locations.location(at: $0.positionAfterSkippingLeadingTrivia) })
    }
}

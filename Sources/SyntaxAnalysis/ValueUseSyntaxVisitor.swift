import SourceGraph
import SwiftSyntax

/// Associates call operands with the indexed expressions that supplied their values.
/// Local variables are absent from the index, so resolve their lexical bindings here.
public final class ValueUseSyntaxVisitor: SyntaxVisitor {
    public private(set) var arguments: [Location: Set<Location>] = [:]
    public private(set) var argumentLists: [Location: [(label: String?, origins: Set<Location>)]] = [:]
    public private(set) var parameterTypeNames: [Location: [ParameterTypeNames]] = [:]
    public private(set) var initializedConstantLocations: Set<Location> = []
    public private(set) var genericTypeLocations: Set<Location> = []
    private var genericNames: [Set<String>] = [[]]
    private let locations: SourceLocationBuilder
    private var scopes: [[String: Set<Location>]] = [[:]]
    /// Whether `Type.self` resolves to the type's own reference. Only the per-argument lists want that; the unioned
    /// value uses that equality and encoding rules read treat a metatype as no value.
    private var resolvesMetatypes = false

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
        recordParameterTypeNames(
            of: node.signature,
            genericParameterClause: node.genericParameterClause,
            genericWhereClause: node.genericWhereClause,
            at: node.name.positionAfterSkippingLeadingTrivia
        )
        return .visitChildren
    }

    override public func visitPost(_: FunctionDeclSyntax) {
        scopes.removeLast()
        genericNames.removeLast()
    }

    override public func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        recordParameterTypeNames(
            of: node.signature,
            genericParameterClause: node.genericParameterClause,
            genericWhereClause: node.genericWhereClause,
            at: node.initKeyword.positionAfterSkippingLeadingTrivia
        )
        return .visitChildren
    }

    override public func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }

            if node.bindingSpecifier.tokenKind == .keyword(.let), binding.initializer != nil {
                initializedConstantLocations.insert(locations.location(at: binding.positionAfterSkippingLeadingTrivia))
            }

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
        let callee = calleeLocation(node.calledExpression)
        arguments[callee, default: []].formUnion(values)
        resolvesMetatypes = true
        argumentLists[callee] = node.arguments.map { (label: $0.label?.text, origins: origins(of: $0.expression)) }
        resolvesMetatypes = false
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
            // `Type.self` names no declaration of its own; the metatype carries the type reference.
            if member.declName.baseName.tokenKind == .keyword(.self), let base = member.base {
                guard resolvesMetatypes else { return [] }

                // `Page<Model>.self` decodes `Model` as well: resolve the specialized type and its arguments.
                if let specialized = base.as(GenericSpecializationExprSyntax.self) {
                    return specializedOrigins(of: specialized)
                }
                return origins(of: base)
            }
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

    private func specializedOrigins(of specialized: GenericSpecializationExprSyntax) -> Set<Location> {
        var result = origins(of: specialized.expression)
        for argument in specialized.genericArgumentClause.arguments {
            if case let .type(type) = argument.argument {
                result.formUnion(TypeSyntaxInspector(sourceLocationBuilder: locations).types(for: type).map {
                    locations.location(at: $0.positionAfterSkippingLeadingTrivia)
                })
            }
        }
        return result
    }

    private func recordParameterTypeNames(
        of signature: FunctionSignatureSyntax,
        genericParameterClause: GenericParameterClauseSyntax?,
        genericWhereClause: GenericWhereClauseSyntax?,
        at position: AbsolutePosition
    ) {
        var constraints: [String: Set<String>] = [:]
        for parameter in genericParameterClause?.parameters ?? [] {
            if let inherited = parameter.inheritedType {
                constraints[parameter.name.text, default: []].formUnion(Self.typeNames(in: inherited))
            }
        }
        for requirement in genericWhereClause?.requirements ?? [] {
            // Only a requirement on the generic parameter itself constrains it; `T.Payload: Decodable` does not.
            guard case let .conformanceRequirement(conformance) = requirement.requirement,
                  let parameter = conformance.leftType.as(IdentifierTypeSyntax.self) else { continue }

            constraints[parameter.name.text, default: []].formUnion(Self.typeNames(in: conformance.rightType))
        }

        parameterTypeNames[locations.location(at: position)] =
            signature.parameterClause.parameters.map { parameter in
                let label = parameter.firstName.tokenKind == .wildcard ? nil : parameter.firstName.text
                let names = Self.decodedMetatypeNames(of: parameter.type, constraints: constraints)
                return ParameterTypeNames(label: label, names: names, isVariadic: parameter.ellipsis != nil)
            }
    }

    /// The names a parameter's type may decode through: only a parameter that takes the metatype of a type, or of an
    /// array of it, can decode it. A generic parameter's constraints apply when the metatype's element is exactly that
    /// parameter, so `Box<T>`, `T?`, an `inout` or function-typed parameter, a plain value and the like contribute
    /// nothing a decoding rule could match.
    private static func decodedMetatypeNames(of type: TypeSyntax, constraints: [String: Set<String>]) -> Set<String> {
        var current = type
        if let attributed = current.as(AttributedTypeSyntax.self) {
            guard !attributed.specifiers.trimmedDescription.contains("inout") else { return [] }

            current = attributed.baseType
        }

        var element: TypeSyntax
        if let metatype = current.as(MetatypeTypeSyntax.self), metatype.metatypeSpecifier.text == "Type" {
            element = metatype.baseType
        } else if let existential = current.as(SomeOrAnyTypeSyntax.self), existential.someOrAnySpecifier.text == "any",
                  let metatype = existential.constraint.as(MetatypeTypeSyntax.self), metatype.metatypeSpecifier.text == "Type"
        {
            // `any Decodable.Type` is the metatype of an existential.
            return typeNames(in: metatype.baseType)
        } else {
            return []
        }

        if let array = element.as(ArrayTypeSyntax.self) {
            element = array.element
        }
        if let identifier = element.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            return Set([identifier.name.text]).union(constraints[identifier.name.text] ?? [])
        }
        if element.is(SomeOrAnyTypeSyntax.self) || element.is(CompositionTypeSyntax.self) {
            return typeNames(in: element)
        }
        return []
    }

    private static func typeNames(in syntax: some SyntaxProtocol) -> Set<String> {
        let collector = TypeNameCollector(viewMode: .sourceAccurate)
        collector.walk(syntax)
        return collector.names
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

private final class TypeNameCollector: SyntaxVisitor {
    var names: Set<String> = []

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    /// A qualified name such as `T.Payload` is a different type from `T`: keep it whole and do not
    /// collect its base. `Swift.Decodable` also counts as `Decodable`.
    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.trimmedDescription)
        if node.baseType.trimmedDescription == "Swift" {
            names.insert(node.name.text)
        }
        return .skipChildren
    }
}

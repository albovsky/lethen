import SourceGraph
import SwiftSyntax

/// Associates call operands with the indexed expressions that supplied their values.
/// Local variables are absent from the index, so resolve their lexical bindings here.
public final class ValueUseSyntaxVisitor: SyntaxVisitor {
    public private(set) var arguments: [Location: Set<Location>] = [:]
    public private(set) var argumentLists: [Location: [(label: String?, origins: Set<Location>)]] = [:]
    public private(set) var parameterTypeNames: [Location: [ParameterTypeNames]] = [:]
    /// Keyed by a function's name location: see `Declaration.returnTypeNames`.
    public private(set) var returnTypeNames: [Location: Set<String>] = [:]
    /// Keyed by a call's callee location: the types its context gives the call's result.
    public private(set) var resultTypes: [Location: Set<Location>] = [:]
    /// Keyed by the specialized type's own location: what each of its generic arguments names.
    public private(set) var specializationArguments: [Location: [Set<Location>]] = [:]
    /// Every type named inside the generic arguments of a stored property's declared type.
    public private(set) var specializationArgumentLocations: Set<Location> = []
    public private(set) var accessorBodyLocations: Set<Location> = []
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

            if let type = binding.typeAnnotation?.type {
                recordSpecializations(in: type)
            }

            if let block = binding.accessorBlock, Self.isComputed(block) {
                accessorBodyLocations.insert(locations.location(at: binding.positionAfterSkippingLeadingTrivia))
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
        if let type = Self.contextualType(of: node) {
            recordSpecializations(in: type)
            resultTypes[callee, default: []].formUnion(tokens(in: type))
        }
        return .visitChildren
    }

    /// The type the context gives a call's result, which fixes a generic result: the annotation of the binding the call
    /// initializes, the type of a plain `as`, or the return type of the function or getter that returns it, by
    /// `return` or as its only statement. `try` and `await` pass it through. Other positions, such as assignment to an
    /// existing property or a closure body, are not modeled.
    private static func contextualType(of call: FunctionCallExprSyntax) -> TypeSyntax? {
        var expression = Syntax(call)
        while let parent = expression.parent, parent.is(TryExprSyntax.self) || parent.is(AwaitExprSyntax.self) {
            expression = parent
        }
        guard let parent = expression.parent else { return nil }

        if let initializer = parent.as(InitializerClauseSyntax.self) {
            return initializer.parent?.as(PatternBindingSyntax.self)?.typeAnnotation?.type
        }
        // The tree is not operator-folded, so `value as T` is a sequence of the operand, the cast and the type.
        if let list = parent.as(ExprListSyntax.self) {
            let items = Array(list)
            if let index = items.firstIndex(where: { $0.id == expression.id }), index + 2 < items.count,
               let cast = items[index + 1].as(UnresolvedAsExprSyntax.self), cast.questionOrExclamationMark == nil,
               let type = items[index + 2].as(TypeExprSyntax.self)
            {
                return type.type
            }
            return nil
        }
        if parent.is(ReturnStmtSyntax.self) {
            return returnType(enclosing: parent)
        }
        if let item = parent.as(CodeBlockItemSyntax.self), let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1,
           let body = list.parent
        {
            // A single expression is the implicit return of a function, accessor or closure body.
            return body.is(ClosureExprSyntax.self) ? nil : returnType(enclosing: body)
        }
        return nil
    }

    /// The declared type of the nearest function, or of the property whose getter the node is in.
    private static func returnType(enclosing node: Syntax) -> TypeSyntax? {
        var current = node.parent
        while let ancestor = current {
            if let function = ancestor.as(FunctionDeclSyntax.self) {
                return function.signature.returnClause?.type
            }
            if let accessor = ancestor.as(AccessorDeclSyntax.self), accessor.accessorSpecifier.tokenKind != .keyword(.get) {
                return nil
            }
            if let binding = ancestor.as(PatternBindingSyntax.self) {
                return binding.typeAnnotation?.type
            }
            if ancestor.is(ClosureExprSyntax.self) || ancestor.is(InitializerDeclSyntax.self) || ancestor.is(SubscriptDeclSyntax.self) {
                return nil
            }
            current = ancestor.parent
        }
        return nil
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

                // `Page<Model>.self` resolves to `Page`, with its arguments recorded for the decoding rule.
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
        if let dictionary = expression.as(DictionaryExprSyntax.self), case let .elements(elements) = dictionary.content {
            return elements.reduce(into: []) { $0.formUnion(origins(of: $1.key).union(origins(of: $1.value))) }
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

    /// A shorthand getter, or an accessor list with a getter, setter, `_read` or `_modify`; `willSet` and `didSet`
    /// observe a stored property.
    private static func isComputed(_ block: AccessorBlockSyntax) -> Bool {
        switch block.accessors {
        case .getter:
            true
        case let .accessors(list):
            list.contains { ["get", "set", "_read", "_modify", "unsafeAddress", "unsafeMutableAddress"].contains($0.accessorSpecifier.text) }
        }
    }

    /// Records the generic specializations in a stored property's declared type, apart from the standard containers,
    /// which pass their arguments through.
    private func recordSpecializations(in type: TypeSyntax) {
        let collector = SpecializationCollector(viewMode: .sourceAccurate)
        collector.walk(type)
        for node in collector.specializations {
            let base = locations.location(at: node.name.positionAfterSkippingLeadingTrivia)
            var arguments: [Set<Location>] = []
            for argument in node.clause.arguments {
                guard case let .type(argumentType) = argument.argument else {
                    arguments.append([])
                    continue
                }

                let named = TypeSyntaxInspector(sourceLocationBuilder: locations).types(for: argumentType)
                specializationArgumentLocations.formUnion(named.map { locations.location(at: $0.positionAfterSkippingLeadingTrivia) })
                arguments.append(Self.simpleTypeTokens(in: argumentType).reduce(into: Set<Location>()) {
                    $0.insert(locations.location(at: $1.positionAfterSkippingLeadingTrivia))
                })
            }
            specializationArguments[base] = arguments
        }
    }

    /// The specialized type itself. Its generic arguments are recorded apart, because whether they are decoded
    /// depends on how the type stores them.
    private func specializedOrigins(of specialized: GenericSpecializationExprSyntax) -> Set<Location> {
        let base = origins(of: specialized.expression)
        let arguments = specialized.genericArgumentClause.arguments.map { argument -> Set<Location> in
            guard case let .type(type) = argument.argument else { return [] }

            return Self.simpleTypeTokens(in: type).reduce(into: Set<Location>()) {
                $0.insert(locations.location(at: $1.positionAfterSkippingLeadingTrivia))
            }
        }
        for location in base {
            specializationArguments[location] = arguments
        }
        return base
    }

    /// The name token of a plain, array or optional type. A nested generic such as `Box<Model>` names nothing here,
    /// since the box may not decode its argument.
    private static func simpleTypeTokens(in type: TypeSyntax) -> [TokenSyntax] {
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            return [identifier.name]
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            return simpleTypeTokens(in: array.element)
        }
        if let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil {
            // `Namespace.Model` is indexed at its last component.
            return [member.name]
        }
        if let dictionary = type.as(DictionaryTypeSyntax.self) {
            return simpleTypeTokens(in: dictionary.key) + simpleTypeTokens(in: dictionary.value)
        }
        if let optional = type.as(OptionalTypeSyntax.self) {
            return simpleTypeTokens(in: optional.wrappedType)
        }
        return []
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

        if let returned = signature.returnClause?.type {
            returnTypeNames[locations.location(at: position)] = Self.returnedGenericNames(of: returned, constraints: constraints)
        }

        parameterTypeNames[locations.location(at: position)] =
            signature.parameterClause.parameters.map { parameter in
                let label = parameter.firstName.tokenKind == .wildcard ? nil : parameter.firstName.text
                let names = Self.decodedMetatypeNames(of: parameter.type, constraints: constraints)
                return ParameterTypeNames(label: label, names: names, isVariadic: parameter.ellipsis != nil, typeName: parameter.type.trimmedDescription)
            }
    }

    /// A generic parameter returned bare or inside optionals and arrays, as `T`, `T?` or `[T]`, with its constraints.
    /// Anything else, including `Box<T>` and a type that merely mentions `T`, leaves the result type unconstrained.
    private static func returnedGenericNames(of type: TypeSyntax, constraints: [String: Set<String>]) -> Set<String> {
        var current = type
        while true {
            if let optional = current.as(OptionalTypeSyntax.self) {
                current = optional.wrappedType
            } else if let unwrapped = current.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
                current = unwrapped.wrappedType
            } else if let array = current.as(ArrayTypeSyntax.self) {
                current = array.element
            } else {
                break
            }
        }
        guard let identifier = current.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil,
              let own = constraints[identifier.name.text] else { return [] }

        return own
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

private final class SpecializationCollector: SyntaxVisitor {
    private static let transparent: Set<String> = ["Array", "Optional", "Set", "Dictionary", "ContiguousArray"]
    var specializations: [(name: TokenSyntax, clause: GenericArgumentClauseSyntax)] = []

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        record(node.name, node.genericArgumentClause)
        return .visitChildren
    }

    /// A qualified type such as `Namespace.Phantom<Model>` is specialized at its last component.
    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        record(node.name, node.genericArgumentClause)
        return .visitChildren
    }

    private func record(_ name: TokenSyntax, _ clause: GenericArgumentClauseSyntax?) {
        if let clause, !Self.transparent.contains(name.text) {
            specializations.append((name, clause))
        }
    }
}

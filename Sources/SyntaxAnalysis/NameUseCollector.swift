import Foundation
import SourceGraph
import SwiftParser
import SwiftSyntax
import SystemPackage

/// The names a piece of syntax uses, as the index would record them as references: calls, member
/// accesses, identifiers, type names, and operators, but not the names of declarations written in it,
/// labels, parameters, or import paths.
///
/// Two callers need the names of code the index has no references for: `SkippedConditionalBranchVisitor`
/// for an `#if` clause the build did not compile, and `UnscannedTargetIndexer` for the files of a target the
/// scanned schemes did not build. Names are kept in the three tiers they are matched in, from weakest to
/// strongest: any use; a use spelled as a member access or a call, which is all that can name a member;
/// and such a use outside a pattern, since matching an enum case in a pattern is not constructing it.
public struct NameUseCollector {
    /// One use of a name.
    public struct Use {
        public let name: String
        /// Whether the use is spelled as a member access or a call.
        public let isMember: Bool
        /// Whether the use is a member access or a call outside every pattern.
        public let isConstruction: Bool
        public let position: AbsolutePosition
    }

    /// Names used, each flagged when some use is a member access or a call.
    public private(set) var uses: [String: Bool] = [:]
    /// Names with a member access or call use outside every pattern.
    public private(set) var constructionUses: Set<String> = []
    /// Each name's spellings: the labels, trailing closure and type of each use, beside the tiers above.
    public private(set) var spellings: [String: Set<NameSites.Spelling>] = [:]
    /// Whether the syntax holds anything the index records an occurrence for, as opposed to nothing but
    /// imports, comments, or whitespace.
    public private(set) var hasIndexableSyntax = false

    /// The modules the syntax imports with `@testable`, whose internal declarations it can use.
    public private(set) var testableModules: Set<String> = []

    private let onUse: ((Use) -> Void)?
    /// The generic parameters and associated types the syntax declares: `T.make()` names whatever `T` is, so no
    /// type narrows the member it uses.
    private var placeholderTypeNames: Set<String> = []
    /// The type extended by the extension around the node being collected, which can use generic parameters and
    /// associated types of that type that no syntax declares.
    private var extendedTypeName: String?
    /// The capitalized names the file binds to values, `let Handler = …` or a parameter `Handler`, against the Swift
    /// API guidelines: calling one, `Handler()`, can run a `callAsFunction` rather than construct a type, and
    /// `Store.shared` through one names no type. Gathered on first use, across the whole file rather than by scope, so
    /// a part of it sees the parameters and locals around it.
    private var capitalizedValueNames: Set<String>?
    /// The names each member of a type binds, gathered on the first bare name in it, so a member is scanned once
    /// rather than once for each of its bare names.
    private var boundNamesByMember: [SyntaxIdentifier: Set<String>] = [:]
    /// The modules the file imports, anywhere in it, and `Swift`, which every file imports. Gathered on first use.
    private var importedModuleNames: Set<String>?
    private let root: Syntax

    /// Collects the uses in `node`, calling `onUse` for each one in source order. `node` can be a part of a larger
    /// declaration, such as the elements of an `#if` clause; the generic parameters and associated types of the
    /// declarations around it count as placeholders too.
    public init(_ node: Syntax, onUse: ((Use) -> Void)? = nil) {
        self.onUse = onUse
        Self.collectPlaceholderTypeNames(node, into: &placeholderTypeNames)
        Self.collectEnclosingPlaceholderTypeNames(of: node, into: &placeholderTypeNames)
        extendedTypeName = Self.enclosingExtendedTypeName(of: node)
        root = node.root
        collect(node, inPattern: false)
    }

    /// Records a use. A name `forFileReaderOnly` reaches `onUse` but not `uses`: `Store.shared` is a second
    /// spelling of a use already recorded by its bare name, and `init` or `subscript` for `Widget(...)` or
    /// `store[key]` would match every initializer or subscript of a module in a skipped `#if` clause, where
    /// no type name narrows the match as it does for a file of an unscanned target. A name `spellingOnly` is kept
    /// as a spelling and nowhere else, so a skipped clause that constructs `Widget` can narrow `init` to
    /// `Widget`'s initializers without naming `init` for every type.
    private mutating func record(
        _ name: String,
        isMember: Bool,
        isConstruction: Bool,
        at node: Syntax,
        forFileReaderOnly: Bool = false,
        spellingOnly: Bool = false,
        inPattern: Bool = false,
        labels: [String]? = nil,
        hasTrailingClosure: Bool = false,
        receiver: String? = nil,
        isMemberAccess: Bool = false,
        qualifier: String? = nil,
        implicitSelfTypes: [String]? = nil
    ) {
        let spelling = NameSites.Spelling(
            labels: labels, hasTrailingClosure: hasTrailingClosure, receiver: receiver, isMember: isMember, isMemberAccess: isMemberAccess,
            qualifier: qualifier, isPattern: inPattern, extendedType: receiver == nil ? nil : extendedTypeName,
            implicitSelfTypes: implicitSelfTypes
        )
        if spellingOnly {
            spellings[name, default: []].insert(spelling)
            return
        }
        if !forFileReaderOnly {
            spellings[name, default: []].insert(spelling)
            uses[name] = (uses[name] ?? false) || isMember
            if isConstruction { constructionUses.insert(name) }
        }
        onUse?(Use(name: name, isMember: isMember, isConstruction: isConstruction, position: node.positionAfterSkippingLeadingTrivia))
    }

    private mutating func collect(_ node: Syntax, inPattern: Bool) {
        if let importDecl = node.as(ImportDeclSyntax.self) {
            let isTestable = importDecl.attributes.contains {
                if case let .attribute(attribute) = $0 { attribute.attributeName.trimmedDescription == "testable" } else { false }
            }
            if isTestable, let module = importDecl.path.first?.name.text {
                testableModules.insert(module)
            }
            return
        }

        // Any other declaration, call, or reference is recorded by the index.
        if node.is(DeclSyntax.self) || node.is(FunctionCallExprSyntax.self)
            || node.is(MemberAccessExprSyntax.self) || node.is(DeclReferenceExprSyntax.self)
            || node.is(BinaryOperatorExprSyntax.self) || node.is(PrefixOperatorExprSyntax.self)
            || node.is(PostfixOperatorExprSyntax.self)
            // Type-only syntax (a cast, a generic argument, a metatype), key paths, subscripts and macros.
            || node.is(IdentifierTypeSyntax.self) || node.is(MemberTypeSyntax.self)
            || node.is(KeyPathExprSyntax.self) || node.is(SubscriptCallExprSyntax.self)
            || node.is(MacroExpansionExprSyntax.self)
        {
            hasIndexableSyntax = true
        }
        // An `override` names the member it overrides, which the declaration's own name does not record as a use,
        // yet removing the base member would stop it compiling.
        for name in Self.overriddenNames(of: node) {
            record(name, isMember: true, isConstruction: true, at: node)
        }
        // Matching an enum case is not constructing it, but a pattern can read any other declaration,
        // as `case Limits.windowsValue:` does, so pattern uses are kept and flagged.
        let inPattern = inPattern || node.is(ExpressionPatternSyntax.self)
        // An operator is used by its spelling alone, so it is never a member use.
        if let binary = node.as(BinaryOperatorExprSyntax.self) {
            record(binary.operator.text, isMember: false, isConstruction: false, at: node)
        } else if let prefix = node.as(PrefixOperatorExprSyntax.self) {
            record(prefix.operator.text, isMember: false, isConstruction: false, at: node)
        } else if let postfix = node.as(PostfixOperatorExprSyntax.self) {
            record(postfix.operator.text, isMember: false, isConstruction: false, at: node)
        } else if let reference = node.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.identifier?.name ?? reference.baseName.text
            // `process<Int>()` wraps the reference in a generic specialization before the call.
            let specialized = reference.parent?.as(GenericSpecializationExprSyntax.self)
            let callee = specialized.flatMap { $0.expression.id == reference.id ? Syntax($0) : nil } ?? Syntax(reference)
            let isCalled = callee.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id == callee.id
            let isMember = reference.parent?.as(MemberAccessExprSyntax.self)?.declName.id == reference.id
                || isCalled
                || reference.parent?.is(KeyPathPropertyComponentSyntax.self) == true
            let call = Self.call(spelling: reference)
            // A call spells labels, so does a reference such as `show(title:)`; a bare name spells none.
            let labels = call.map { Self.labels(of: $0) } ?? reference.argumentNames?.arguments.map(\.name.text)
            let access = reference.parent?.as(MemberAccessExprSyntax.self)
            let qualifier = access.flatMap { $0.declName.id == reference.id ? qualifierName(of: $0) : nil }
            // A capitalized value, `func use(Store: B.Type) { Store.shared }`, names no type.
            var receiver = qualifier.flatMap { $0.first?.isUppercase == true ? $0 : nil }
            if let name = receiver, isCapitalizedValue(name) {
                receiver = nil
            }
            // `store.value` and `Store.value` reach the name through something; `value` and `value()` do not.
            let isMemberAccess = access?.declName.id == reference.id
                || reference.parent?.is(KeyPathPropertyComponentSyntax.self) == true
            record(
                name, isMember: isMember, isConstruction: isMember && !inPattern, at: node, inPattern: inPattern,
                labels: labels, hasTrailingClosure: call.map { $0.trailingClosure != nil } ?? false, receiver: receiver,
                isMemberAccess: isMemberAccess, qualifier: qualifier
            )
            // Inside a type's body a bare name, `logger` or the `logger` of `logger.info()`, can read a member of that
            // type without `self.`, unless the member around it binds a value of that name.
            // A generic parameter of that name, `T` in `func f<T>()`, is what the name refers to.
            if !isMember, !isMemberAccess, reference.baseName.identifier != nil, !placeholderTypeNames.contains(name),
               let types = implicitSelfTypes(of: name, at: node)
            {
                record(
                    name, isMember: true, isConstruction: !inPattern, at: node, spellingOnly: true, inPattern: inPattern,
                    labels: labels, implicitSelfTypes: types
                )
            }
            // `Widget(...)` calls an initializer of `Widget`, which the index records under `init`; a type name
            // starts with a capital letter, a function does not. The use is also recorded as `Widget.init`, so
            // a match can be placed at a use of this type's initializer rather than any type's.
            // `Framework.Widget<Int>()` wraps the access in a generic specialization before the call.
            let qualifiedCallee = access.map { access in
                access.parent?.as(GenericSpecializationExprSyntax.self).flatMap { $0.expression.id == access.id ? Syntax($0) : nil } ?? Syntax(access)
            }
            let isQualifiedTypeCall = access?.declName.id == reference.id
                && qualifiedCallee?.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id == qualifiedCallee?.id
            if (isCalled && access == nil) || isQualifiedTypeCall, name.first?.isUppercase == true {
                record("init", isMember: true, isConstruction: !inPattern, at: node, forFileReaderOnly: true)
                record("\(name).init", isMember: true, isConstruction: !inPattern, at: node, forFileReaderOnly: true)
                // The construction also spells `init` through the type, with the call's labels, which narrows a
                // skipped use to this type's initializers. A generic parameter or `Self` stands for any type.
                if let call = Self.call(spelling: reference) {
                    let constructed = name == "Self" || placeholderTypeNames.contains(name) ? nil : name
                    // `Foundation.TimeInterval(...)` keeps its qualifier when the file imports it, so it names a
                    // module. Any other qualifier, `NSString` in `NSString.Widget(...)`, may be a type.
                    let module = constructed == nil || !isQualifiedTypeCall ? nil : qualifier.flatMap { isImportedModule($0) ? $0 : nil }
                    record(
                        "init", isMember: true, isConstruction: !inPattern, at: node, spellingOnly: true, inPattern: inPattern,
                        labels: Self.labels(of: call), hasTrailingClosure: call.trailingClosure != nil, receiver: constructed,
                        qualifier: module
                    )
                }
            }
            // `Store.shared` names the member through its type; recorded as `Store.shared` as well.
            if let access, access.declName.id == reference.id,
               let base = access.base?.as(DeclReferenceExprSyntax.self)?.baseName.text, base.first?.isUppercase == true
            {
                record("\(base).\(name)", isMember: true, isConstruction: !inPattern, at: node, forFileReaderOnly: true)
            }
        } else if let type = node.as(IdentifierTypeSyntax.self) {
            let name = type.name.identifier?.name ?? type.name.text
            record(name, isMember: false, isConstruction: false, at: node)
        } else if let type = node.as(MemberTypeSyntax.self) {
            let name = type.name.identifier?.name ?? type.name.text
            // `Outer.Inner` reaches the type through `Outer`, which `Module.Widget` spells as the module.
            let base = type.baseType.as(IdentifierTypeSyntax.self)?.name.identifier?.name
            let qualifier = base.flatMap { placeholderTypeNames.contains($0) ? nil : $0 }
            let receiver = qualifier.flatMap { $0.first?.isUppercase == true ? $0 : nil }
            record(
                name, isMember: true, isConstruction: !inPattern, at: node,
                receiver: receiver, isMemberAccess: true, qualifier: qualifier
            )
        } else if onUse != nil, let call = node.as(FunctionCallExprSyntax.self), isCallableValueCall(call) {
            // `Handler()()` or `handler(1)` can run a `callAsFunction`, which the call never spells; like `init`
            // and `subscript`, only a file that names the type can match it.
            record("callAsFunction", isMember: true, isConstruction: !inPattern, at: node, forFileReaderOnly: true)
        } else if node.is(SubscriptCallExprSyntax.self) {
            // `store[key]` is a use of a subscript, which the index records under that name.
            record("subscript", isMember: true, isConstruction: !inPattern, at: node, forFileReaderOnly: true)
        } else if let macro = node.as(MacroExpansionExprSyntax.self) {
            // `#makeWidget()` names the macro in its own token, not in a reference.
            record(macro.macroName.text, isMember: false, isConstruction: false, at: node, forFileReaderOnly: true)
        } else if let macro = node.as(MacroExpansionDeclSyntax.self) {
            record(macro.macroName.text, isMember: false, isConstruction: false, at: node, forFileReaderOnly: true)
        }
        let outerExtendedTypeName = extendedTypeName
        let extensionDecl = node.as(ExtensionDeclSyntax.self)
        for child in node.children(viewMode: .sourceAccurate) {
            // The extended type itself is spelled outside the extension's scope.
            if let extensionDecl, child.id != extensionDecl.extendedType.id {
                extendedTypeName = Self.baseName(of: extensionDecl.extendedType)
            }
            collect(child, inPattern: inPattern)
            extendedTypeName = outerExtendedTypeName
        }
    }

    /// The base names of the types and extensions around `node`, innermost first, for a bare `name` that can read one of
    /// their members; `nil` outside any type, or when the declaration directly inside the innermost type, such as the
    /// method holding the use, binds a value of that name anywhere: a local, a parameter, a pattern or a local function.
    private mutating func implicitSelfTypes(of name: String, at node: Syntax) -> [String]? {
        var types: [String] = []
        var member: Syntax?
        var current: Syntax? = node
        while let syntax = current {
            if let name = Self.typeName(of: syntax) {
                types.append(name)
            } else if types.isEmpty, member == nil, syntax.parent?.is(MemberBlockItemSyntax.self) == true {
                // The innermost one: a type-level `#if` around the method is a member too, holding its siblings.
                member = syntax
            }
            current = syntax.parent
        }
        guard !types.isEmpty else { return nil }

        if let member {
            if boundNamesByMember[member.id] == nil {
                var bound: Set<String> = []
                Self.collectBoundValueNames(member, into: &bound)
                Self.collectLocalDeclarationNames(in: member, into: &bound)
                boundNamesByMember[member.id] = bound
            }
            if boundNamesByMember[member.id]?.contains(name) == true { return nil }
        }
        return types
    }

    /// The names of the functions, types and type aliases declared inside `member`, not `member` itself: a bare name
    /// in it names one of them rather than a member of the type.
    private static func collectLocalDeclarationNames(in member: Syntax, into names: inout Set<String>) {
        for child in member.children(viewMode: .sourceAccurate) {
            if let name = (child.as(FunctionDeclSyntax.self)?.name ?? child.as(TypeAliasDeclSyntax.self)?.name)?.identifier?.name
                ?? typeName(of: child)
            {
                names.insert(name)
            }
            collectLocalDeclarationNames(in: child, into: &names)
        }
    }

    /// The name a type declaration declares, without backticks: `Store` for ``struct `Store` {}``.
    private static func typeName(of node: Syntax) -> String? {
        let name: TokenSyntax? = if let decl = node.as(ClassDeclSyntax.self) {
            decl.name
        } else if let decl = node.as(StructDeclSyntax.self) {
            decl.name
        } else if let decl = node.as(EnumDeclSyntax.self) {
            decl.name
        } else if let decl = node.as(ActorDeclSyntax.self) {
            decl.name
        } else if let decl = node.as(ProtocolDeclSyntax.self) {
            decl.name
        } else {
            nil
        }
        if let name { return name.identifier?.name ?? name.text }
        if let decl = node.as(ExtensionDeclSyntax.self) { return baseName(of: decl.extendedType) }
        return nil
    }

    /// The type extended by the innermost extension around `node`.
    private static func enclosingExtendedTypeName(of node: Syntax) -> String? {
        var current = node.parent
        while let ancestor = current {
            if let extensionDecl = ancestor.as(ExtensionDeclSyntax.self) {
                return baseName(of: extensionDecl.extendedType)
            }
            current = ancestor.parent
        }
        return nil
    }

    /// The last component of a type's name, without generic arguments: `Array` for `Swift.Array<Int>`.
    private static func baseName(of type: TypeSyntax) -> String {
        if let member = type.as(MemberTypeSyntax.self) {
            return member.name.identifier?.name ?? member.name.text
        }
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifier.name.identifier?.name ?? identifier.name.text
        }
        return type.trimmedDescription
    }

    /// The call whose callee is `reference`, spelled `foo(...)`, `base.foo(...)` or either with generic arguments.
    private static func call(spelling reference: DeclReferenceExprSyntax) -> FunctionCallExprSyntax? {
        var callee = Syntax(reference)
        if let access = reference.parent?.as(MemberAccessExprSyntax.self), access.declName.id == reference.id {
            callee = Syntax(access)
        }
        if let specialized = callee.parent?.as(GenericSpecializationExprSyntax.self), specialized.expression.id == callee.id {
            callee = Syntax(specialized)
        }
        guard let call = callee.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == callee.id else { return nil }

        return call
    }

    /// The labels a call spells, `_` for an unlabeled argument, followed by those of its labeled trailing closures.
    private static func labels(of call: FunctionCallExprSyntax) -> [String] {
        call.arguments.map { $0.label?.text ?? "_" } + call.additionalTrailingClosures.map(\.label.text)
    }

    /// The identifier a member access is spelled through, whatever its case: `Store` in `Store.shared`,
    /// `store` in `store.shared`, `app` in `app.logger`. Anything else, `self.shared`, `Self.shared`,
    /// `Outer.Inner.shared`, or a name that stands for a type chosen elsewhere, names none. An uppercase one
    /// is the `receiver`, the type a member is reached through; a lowercase one can still be a module.
    private func qualifierName(of access: MemberAccessExprSyntax) -> String? {
        guard let base = access.base?.as(DeclReferenceExprSyntax.self), base.argumentNames == nil,
              let name = base.baseName.identifier?.name, !placeholderTypeNames.contains(name)
        else { return nil }

        return name
    }

    /// The generic parameters and associated types that declarations around `node` declare.
    private static func collectEnclosingPlaceholderTypeNames(of node: Syntax, into names: inout Set<String>) {
        var current = node.parent
        while let ancestor = current {
            for child in ancestor.children(viewMode: .sourceAccurate) {
                if let clause = child.as(GenericParameterClauseSyntax.self) {
                    for parameter in clause.parameters {
                        names.insert(parameter.name.identifier?.name ?? parameter.name.text)
                    }
                }
            }
            if let protocolDecl = ancestor.as(ProtocolDeclSyntax.self) {
                for member in protocolDecl.memberBlock.members {
                    if let associated = member.decl.as(AssociatedTypeDeclSyntax.self) { names.insert(associated.name.identifier?.name ?? associated.name.text) }
                }
            }
            current = ancestor.parent
        }
    }

    private mutating func isImportedModule(_ name: String) -> Bool {
        if importedModuleNames == nil {
            var names: Set<String> = ["Swift"]
            Self.collectImportedModuleNames(root, into: &names)
            importedModuleNames = names
        }
        return importedModuleNames?.contains(name) == true
    }

    private static func collectImportedModuleNames(_ node: Syntax, into names: inout Set<String>) {
        if let importDecl = node.as(ImportDeclSyntax.self) {
            if let module = importDecl.path.first?.name.text { names.insert(module) }
            return
        }
        for child in node.children(viewMode: .sourceAccurate) {
            collectImportedModuleNames(child, into: &names)
        }
    }

    private mutating func isCapitalizedValue(_ name: String) -> Bool {
        if capitalizedValueNames == nil {
            var names: Set<String> = []
            Self.collectCapitalizedValueNames(root, into: &names)
            capitalizedValueNames = names
        }
        return capitalizedValueNames?.contains(name) == true
    }

    private static func collectCapitalizedValueNames(_ node: Syntax, into names: inout Set<String>) {
        var bound: Set<String> = []
        collectBoundValueNames(node, into: &bound)
        names.formUnion(bound.filter { $0.first?.isUppercase == true })
    }

    /// The names `node` binds to values: `let` and `var` bindings and other identifier patterns, function and
    /// closure parameters by their local names, a closure's captures, `[logger = …]`, the parameters of
    /// accessors, `set(value)` or the implicit `newValue` of `set`, `willSet` and `init` and `oldValue` of
    /// `didSet`, and a bare `catch`'s implicit `error`.
    private static func collectBoundValueNames(_ node: Syntax, into names: inout Set<String>) {
        let bound: TokenSyntax? = if let pattern = node.as(IdentifierPatternSyntax.self) {
            pattern.identifier
        } else if let parameter = node.as(FunctionParameterSyntax.self) {
            parameter.secondName ?? parameter.firstName
        } else if let parameter = node.as(ClosureParameterSyntax.self) {
            parameter.secondName ?? parameter.firstName
        } else if let parameter = node.as(ClosureShorthandParameterSyntax.self) {
            parameter.name
        } else if let parameters = node.as(AccessorParametersSyntax.self) {
            parameters.name
        } else if let capture = node.as(ClosureCaptureSyntax.self) {
            capture.name
        } else {
            nil
        }
        if let name = bound?.identifier?.name {
            names.insert(name)
        }
        // `catch` and `catch where error is Failure` bind `error` themselves; `catch let failure` does not.
        if let clause = node.as(CatchClauseSyntax.self), clause.catchItems.isEmpty || clause.catchItems.contains(where: { $0.pattern == nil }) {
            names.insert("error")
        }
        if let accessor = node.as(AccessorDeclSyntax.self), accessor.parameters == nil {
            switch accessor.accessorSpecifier.tokenKind {
            case .keyword(.set), .keyword(.willSet), .keyword(.`init`): names.insert("newValue")
            case .keyword(.didSet): names.insert("oldValue")
            default: break
            }
        }
        for child in node.children(viewMode: .sourceAccurate) {
            collectBoundValueNames(child, into: &names)
        }
    }

    private static func collectPlaceholderTypeNames(_ node: Syntax, into names: inout Set<String>) {
        if let parameter = node.as(GenericParameterSyntax.self) {
            names.insert(parameter.name.identifier?.name ?? parameter.name.text)
        } else if let associated = node.as(AssociatedTypeDeclSyntax.self) {
            names.insert(associated.name.identifier?.name ?? associated.name.text)
        }
        for child in node.children(viewMode: .sourceAccurate) {
            collectPlaceholderTypeNames(child, into: &names)
        }
    }

    /// The names a declaration with the `override` modifier overrides: a function's, each bound variable's,
    /// `init` or `subscript`.
    private static func overriddenNames(of node: Syntax) -> [String] {
        func isOverride(_ modifiers: DeclModifierListSyntax) -> Bool {
            modifiers.contains { $0.name.text == "override" }
        }
        if let function = node.as(FunctionDeclSyntax.self), isOverride(function.modifiers) {
            return [function.name.identifier?.name ?? function.name.text]
        }
        if let variable = node.as(VariableDeclSyntax.self), isOverride(variable.modifiers) {
            return variable.bindings.flatMap { binding -> [String] in
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { return [] }

                return [identifier.identifier.identifier?.name ?? identifier.identifier.text]
            }
        }
        if let initializer = node.as(InitializerDeclSyntax.self), isOverride(initializer.modifiers) {
            return ["init"]
        }
        if let subscriptDecl = node.as(SubscriptDeclSyntax.self), isOverride(subscriptDecl.modifiers) {
            return ["subscript"]
        }
        return []
    }

    /// Whether the call's callee is a value rather than a function or type name that the index resolves: a call,
    /// a subscript, a parenthesized, unwrapped or chained expression, or a lowercase name, since a type name
    /// starts with a capital letter; leading underscores are skipped, so `_handler` is a value, and so is a shorthand argument such as `$0`. A call of a local function matches too, which only costs a name that no
    /// type named by the file can narrow to a `callAsFunction`. A capitalized name in `capitalizedValueNames` is a
    /// value too: `Handler()` may then also be a construction, which is still recorded as one.
    private mutating func isCallableValueCall(_ call: FunctionCallExprSyntax) -> Bool {
        var callee = call.calledExpression
        if let specialized = callee.as(GenericSpecializationExprSyntax.self) { callee = specialized.expression }
        let calledName = callee.as(DeclReferenceExprSyntax.self)?.baseName.text ?? callee.as(MemberAccessExprSyntax.self)?.declName.baseName.text
        if let name = calledName {
            // `$0` is a closure's shorthand argument, a value whatever it holds. A capitalized name is a type unless
            // the file binds it to a value, when the call may be either.
            return name.hasPrefix("$") || name.first(where: { $0 != "_" })?.isLowercase == true || isCapitalizedValue(name)
        }
        return callee.is(FunctionCallExprSyntax.self) || callee.is(SubscriptCallExprSyntax.self)
            || callee.is(TupleExprSyntax.self) || callee.is(ForceUnwrapExprSyntax.self) || callee.is(OptionalChainingExprSyntax.self)
    }

    /// A use of a name in a source file, with the line it is on.
    public struct FileUse {
        public let name: String
        public let isMember: Bool
        public let isConstruction: Bool
        public let line: Int
    }

    /// What a file uses: each name with its line, and the modules it imports with `@testable`.
    public struct FileUses {
        public let uses: [FileUse]
        public let testableModules: Set<String>
    }

    /// Every use in the Swift file at `path`. Throws when the file cannot be read as UTF-8; a file that
    /// does not parse cleanly still yields the uses SwiftSyntax recovered.
    public static func uses(inFileAt path: FilePath) throws -> FileUses {
        let source = try String(contentsOf: path.url, encoding: .utf8)
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path.string, tree: tree)
        var fileUses: [FileUse] = []
        let collector = NameUseCollector(Syntax(tree)) { use in
            fileUses.append(FileUse(name: use.name, isMember: use.isMember, isConstruction: use.isConstruction, line: converter.location(for: use.position).line))
        }
        return FileUses(uses: fileUses, testableModules: collector.testableModules)
    }
}

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

    /// Collects the uses in `node`, calling `onUse` for each one in source order.
    public init(_ node: Syntax, onUse: ((Use) -> Void)? = nil) {
        self.onUse = onUse
        Self.collectPlaceholderTypeNames(node, into: &placeholderTypeNames)
        collect(node, inPattern: false)
    }

    /// Records a use. A name `forFileReaderOnly` reaches `onUse` but not `uses`: `Store.shared` is a second
    /// spelling of a use already recorded by its bare name, and `init` or `subscript` for `Widget(...)` or
    /// `store[key]` would match every initializer or subscript of a module in a skipped `#if` clause, where
    /// no type name narrows the match as it does for a file of an unscanned target.
    private mutating func record(
        _ name: String,
        isMember: Bool,
        isConstruction: Bool,
        at node: Syntax,
        forFileReaderOnly: Bool = false,
        labels: [String]? = nil,
        hasTrailingClosure: Bool = false,
        receiver: String? = nil
    ) {
        if !forFileReaderOnly {
            spellings[name, default: []].insert(
                NameSites.Spelling(labels: labels, hasTrailingClosure: hasTrailingClosure, receiver: receiver, isMember: isMember)
            )
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
            let receiver = access.flatMap { $0.declName.id == reference.id ? receiverName(of: $0) : nil }
            record(
                name, isMember: isMember, isConstruction: isMember && !inPattern, at: node,
                labels: labels, hasTrailingClosure: call.map { $0.trailingClosure != nil } ?? false, receiver: receiver
            )
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
            record(name, isMember: true, isConstruction: !inPattern, at: node)
        } else if let call = node.as(FunctionCallExprSyntax.self), Self.isCallableValueCall(call) {
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
        for child in node.children(viewMode: .sourceAccurate) {
            collect(child, inPattern: inPattern)
        }
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

    /// The type a member access is spelled through: `Store` in `Store.shared`. Anything else, `self.shared`,
    /// `store.shared`, `Outer.Inner.shared`, or a name that stands for a type chosen elsewhere, names none.
    private func receiverName(of access: MemberAccessExprSyntax) -> String? {
        guard let base = access.base?.as(DeclReferenceExprSyntax.self), base.argumentNames == nil else { return nil }

        let name = base.baseName.identifier?.name ?? base.baseName.text
        guard name.first?.isUppercase == true, name != "Self", !placeholderTypeNames.contains(name) else { return nil }

        return name
    }

    private static func collectPlaceholderTypeNames(_ node: Syntax, into names: inout Set<String>) {
        if let parameter = node.as(GenericParameterSyntax.self) {
            names.insert(parameter.name.text)
        } else if let associated = node.as(AssociatedTypeDeclSyntax.self) {
            names.insert(associated.name.text)
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
    /// type named by the file can narrow to a `callAsFunction`.
    private static func isCallableValueCall(_ call: FunctionCallExprSyntax) -> Bool {
        var callee = call.calledExpression
        if let specialized = callee.as(GenericSpecializationExprSyntax.self) { callee = specialized.expression }
        func isValueName(_ name: String) -> Bool {
            // `$0` is a closure's shorthand argument, a value whatever it holds.
            name.hasPrefix("$") || name.first(where: { $0 != "_" })?.isLowercase == true
        }
        if let reference = callee.as(DeclReferenceExprSyntax.self) {
            return isValueName(reference.baseName.text)
        }
        if let access = callee.as(MemberAccessExprSyntax.self) {
            return isValueName(access.declName.baseName.text)
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

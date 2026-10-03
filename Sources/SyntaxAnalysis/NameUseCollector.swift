import Foundation
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
    /// Whether the syntax holds anything the index records an occurrence for, as opposed to nothing but
    /// imports, comments, or whitespace.
    public private(set) var hasIndexableSyntax = false

    private let onUse: ((Use) -> Void)?

    /// Collects the uses in `node`, calling `onUse` for each one in source order.
    public init(_ node: Syntax, onUse: ((Use) -> Void)? = nil) {
        self.onUse = onUse
        collect(node, inPattern: false)
    }

    private mutating func record(_ name: String, isMember: Bool, isConstruction: Bool, at node: Syntax) {
        uses[name] = (uses[name] ?? false) || isMember
        if isConstruction { constructionUses.insert(name) }
        onUse?(Use(name: name, isMember: isMember, isConstruction: isConstruction, position: node.positionAfterSkippingLeadingTrivia))
    }

    private mutating func collect(_ node: Syntax, inPattern: Bool) {
        if node.is(ImportDeclSyntax.self) { return }

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
            let isMember = reference.parent?.as(MemberAccessExprSyntax.self)?.declName.id == reference.id
                || callee.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id == callee.id
                || reference.parent?.is(KeyPathPropertyComponentSyntax.self) == true
            record(name, isMember: isMember, isConstruction: isMember && !inPattern, at: node)
        } else if let type = node.as(IdentifierTypeSyntax.self) {
            let name = type.name.identifier?.name ?? type.name.text
            record(name, isMember: false, isConstruction: false, at: node)
        } else if let type = node.as(MemberTypeSyntax.self) {
            let name = type.name.identifier?.name ?? type.name.text
            record(name, isMember: true, isConstruction: !inPattern, at: node)
        }
        for child in node.children(viewMode: .sourceAccurate) {
            collect(child, inPattern: inPattern)
        }
    }

    /// A use of a name in a source file, with the line it is on.
    public struct FileUse {
        public let name: String
        public let isMember: Bool
        public let isConstruction: Bool
        public let line: Int
    }

    /// Every use in the Swift file at `path`. Throws when the file cannot be read as UTF-8; a file that
    /// does not parse cleanly still yields the uses SwiftSyntax recovered.
    public static func uses(inFileAt path: FilePath) throws -> [FileUse] {
        let source = try String(contentsOf: path.url, encoding: .utf8)
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path.string, tree: tree)
        var fileUses: [FileUse] = []
        _ = NameUseCollector(Syntax(tree)) { use in
            fileUses.append(FileUse(name: use.name, isMember: use.isMember, isConstruction: use.isConstruction, line: converter.location(for: use.position).line))
        }
        return fileUses
    }
}

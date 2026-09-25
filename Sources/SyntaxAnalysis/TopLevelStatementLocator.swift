import SourceGraph
import SwiftSyntax

/// Locates top-level statements and expressions, which only occur in a program's main file.
///
/// References inside these statements belong to the program's top-level code, not to any declaration, so
/// they must never be attributed to a nearby declaration by location.
public enum TopLevelStatementLocator {
    public static func ranges(
        in syntax: SourceFileSyntax,
        using locationBuilder: SourceLocationBuilder
    ) -> [ClosedRange<Location>] {
        var ranges: [ClosedRange<Location>] = []
        collect(syntax.statements, into: &ranges, using: locationBuilder)
        return ranges
    }

    // MARK: - Private

    private static func collect(
        _ items: CodeBlockItemListSyntax,
        into ranges: inout [ClosedRange<Location>],
        using locationBuilder: SourceLocationBuilder
    ) {
        for item in items {
            switch item.item {
            case .stmt, .expr:
                // Freestanding macros such as `#Preview` may appear at the top level of any file. They generate
                // declarations rather than top-level code, and their references are attributed elsewhere.
                guard !isMacroExpansion(item.item) else { continue }

                let start = locationBuilder.location(at: item.positionAfterSkippingLeadingTrivia)
                let end = locationBuilder.location(at: item.endPositionBeforeTrailingTrivia)
                ranges.append(start ... end)
            case let .decl(decl):
                // Top-level statements may be conditionally compiled.
                guard let ifConfig = decl.as(IfConfigDeclSyntax.self) else { continue }

                for clause in ifConfig.clauses {
                    if case let .statements(statements) = clause.elements {
                        collect(statements, into: &ranges, using: locationBuilder)
                    }
                }
            }
        }
    }

    private static func isMacroExpansion(_ item: CodeBlockItemSyntax.Item) -> Bool {
        switch item {
        case let .expr(expr):
            expr.is(MacroExpansionExprSyntax.self)
        case let .stmt(stmt):
            stmt.as(ExpressionStmtSyntax.self)?.expression.is(MacroExpansionExprSyntax.self) ?? false
        case .decl:
            false
        }
    }
}

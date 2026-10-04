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
/// names of declarations written in the clause, labels, parameters, and import paths do not. A use in
/// a pattern counts for everything but an enum case.
public final class SkippedConditionalBranchVisitor: SyntaxVisitor {
    /// Each used name mapped to the lexicographically smallest description of a skipped clause
    /// that uses it, such as `#if os(Windows) at File.swift:12`.
    public private(set) var names: [String: String] = [:]

    /// The subset of `names` with a use spelled as a member access or a call.
    public private(set) var memberNames: [String: String] = [:]

    /// The subset of `memberNames` with a use outside a pattern. Matching an enum case in a pattern
    /// is not constructing it, so an enum case is downgraded only by these.
    public private(set) var constructionNames: [String: String] = [:]

    /// Every spelling of each used name with the smallest site that spells it that way.
    public private(set) var spellings: [String: [NameSites.Spelling: String]] = [:]

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

            let content = NameUseCollector(Syntax(elements))
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
            for (identifier, spelled) in content.spellings {
                for spelling in spelled where spellings[identifier, default: [:]][spelling].map({ $0 > site }) ?? true {
                    spellings[identifier, default: [:]][spelling] = site
                }
            }
            for identifier in content.constructionUses where constructionNames[identifier].map({ $0 > site }) ?? true {
                constructionNames[identifier] = site
            }
        }
        return .visitChildren
    }
}

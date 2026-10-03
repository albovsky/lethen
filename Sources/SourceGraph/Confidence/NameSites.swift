/// Names used by some code, in the three tiers `NameUseCollector` distinguishes, each mapped to the
/// lexicographically smallest site that uses it, such as `Widgets/Extension/Widgets.swift:15`.
public struct NameSites: Equatable {
    public var names: [String: String]
    /// The subset of `names` used as a member access or a call.
    public var memberNames: [String: String]
    /// The subset of `memberNames` used outside a pattern, which is all that can construct an enum case.
    public var constructionNames: [String: String]

    public init(names: [String: String] = [:], memberNames: [String: String] = [:], constructionNames: [String: String] = [:]) {
        self.names = names
        self.memberNames = memberNames
        self.constructionNames = constructionNames
    }

    /// Keeps the smallest site for each name.
    public mutating func merge(_ other: NameSites) {
        names.merge(other.names) { min($0, $1) }
        memberNames.merge(other.memberNames) { min($0, $1) }
        constructionNames.merge(other.constructionNames) { min($0, $1) }
    }
}

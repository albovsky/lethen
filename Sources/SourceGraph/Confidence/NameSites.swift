/// Names used by some code, in the three tiers `NameUseCollector` distinguishes, each mapped to the
/// lexicographically smallest site that uses it, such as `Widgets/Extension/Widgets.swift:15`.
public struct NameSites: Equatable {
    /// How one use of a name is spelled, beside the three tiers: with which argument labels, and through
    /// which type. Only skipped `#if` evidence reads it, to match a declaration a use can be of.
    public struct Spelling: Hashable {
        /// The argument labels of a call, `_` for an unlabeled argument, or of a reference spelled with
        /// them (`show(title:)`); `nil` for a reference that names the function without labels, which any
        /// declaration of the name can match.
        public var labels: [String]?
        /// Whether the call has a trailing closure, which fills one parameter the labels do not spell.
        public var hasTrailingClosure: Bool
        /// The base name of the type a member is spelled through, as in `Store.shared` or `Store.init(...)`;
        /// `nil` when the use names no type, `self.shared`, `shared`, `store.shared`, or names one that may
        /// stand for any type (`Self`, a generic parameter).
        public var receiver: String?
        /// Whether the use is a member access or a call.
        public var isMember: Bool
        /// Whether the use is inside a pattern, `case .ready:`, where an enum case is matched, not constructed.
        public var isPattern: Bool

        public init(
            labels: [String]? = nil,
            hasTrailingClosure: Bool = false,
            receiver: String? = nil,
            isMember: Bool = false,
            isPattern: Bool = false
        ) {
            self.labels = labels
            self.hasTrailingClosure = hasTrailingClosure
            self.receiver = receiver
            self.isMember = isMember
            self.isPattern = isPattern
        }
    }

    public var names: [String: String]
    /// The subset of `names` used as a member access or a call.
    public var memberNames: [String: String]
    /// The subset of `memberNames` used outside a pattern, which is all that can construct an enum case.
    public var constructionNames: [String: String]

    /// Every spelling of each name with its smallest site. Evidence built without it falls back to the maps above.
    public var spellings: [String: [Spelling: String]]

    public init(
        names: [String: String] = [:],
        memberNames: [String: String] = [:],
        constructionNames: [String: String] = [:],
        spellings: [String: [Spelling: String]] = [:]
    ) {
        self.names = names
        self.memberNames = memberNames
        self.constructionNames = constructionNames
        self.spellings = spellings
    }

    /// Keeps the smallest site for each name.
    public mutating func merge(_ other: NameSites) {
        names.merge(other.names) { min($0, $1) }
        memberNames.merge(other.memberNames) { min($0, $1) }
        constructionNames.merge(other.constructionNames) { min($0, $1) }
        spellings.merge(other.spellings) { $0.merging($1) { min($0, $1) } }
    }
}

/// A release tag ordered by Semantic Versioning precedence.
///
/// Unlike a numeric string comparison, a release ranks above all of its own prereleases, so `3.8.1` is newer than
/// both `3.8.1-dev.2` and `3.8.1-beta`.
public struct ReleaseVersion: Comparable, CustomStringConvertible {
    public let tag: String
    private let core: [Int]
    private let prereleaseIdentifiers: [String]

    public init?(_ tag: String) {
        let withoutBuildMetadata = tag.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutBuildMetadata.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }

        guard !core.isEmpty, core.allSatisfy({ $0 != nil }) else { return nil }

        let prereleaseIdentifiers = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []

        guard parts.count == 1 || !prereleaseIdentifiers.isEmpty else { return nil }

        self.tag = tag
        self.core = core.compactMap(\.self)
        self.prereleaseIdentifiers = prereleaseIdentifiers
    }

    public var isPrerelease: Bool {
        !prereleaseIdentifiers.isEmpty
    }

    public var description: String {
        tag
    }

    /// The newest of the given release tags, ignoring prereleases unless `includingPrereleases` is set.
    /// Tags that are not versions are ignored.
    public static func latest(
        of releases: [(tag: String, isPrerelease: Bool)],
        includingPrereleases: Bool
    ) -> ReleaseVersion? {
        releases
            .filter { includingPrereleases || !$0.isPrerelease }
            .compactMap { ReleaseVersion($0.tag) }
            .filter { includingPrereleases || !$0.isPrerelease }
            .max()
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let length = max(lhs.core.count, rhs.core.count)

        for index in 0 ..< length {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0

            if left != right {
                return left < right
            }
        }

        // A version without prerelease identifiers has higher precedence than one with them.
        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (false, false): return false
        case (false, true): return false
        case (true, false): return true
        case (true, true): break
        }

        for (left, right) in zip(lhs.prereleaseIdentifiers, rhs.prereleaseIdentifiers) where left != right {
            switch (Int(left), Int(right)) {
            case let (left?, right?): return left < right
            // Numeric identifiers have lower precedence than alphanumeric identifiers.
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left < right
            }
        }

        return lhs.prereleaseIdentifiers.count < rhs.prereleaseIdentifiers.count
    }
}

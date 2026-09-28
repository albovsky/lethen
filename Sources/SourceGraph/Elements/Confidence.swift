/// How sure Lethen is that a reported declaration is unused. `likely` marks declarations a
/// dynamic feature could reach without a visible reference.
public enum Confidence: String, Comparable {
    case certain
    case likely

    private var rank: Int {
        self == .certain ? 0 : 1
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct ConfidenceAssessment: Equatable {
    public let confidence: Confidence
    /// Why the confidence is `likely`; nil when it is `certain`.
    public let reason: String?

    public init(confidence: Confidence, reason: String?) {
        self.confidence = confidence
        self.reason = reason
    }
}

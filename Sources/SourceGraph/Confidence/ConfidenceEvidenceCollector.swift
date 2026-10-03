import Synchronization

/// Collects `ConfidenceEvidence` from index jobs that run in parallel.
public final class ConfidenceEvidenceCollector: @unchecked Sendable {
    private let evidence = Mutex(ConfidenceEvidence())

    public init() {}

    public func add(_ body: (inout ConfidenceEvidence) -> Void) {
        evidence.withLock { body(&$0) }
    }

    public func snapshot() -> ConfidenceEvidence {
        evidence.withLock { $0 }
    }
}

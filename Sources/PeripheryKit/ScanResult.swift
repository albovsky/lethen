import Foundation
import SourceGraph

public struct ScanResult {
    enum Annotation {
        case unused
        case assignOnlyProperty
        case redundantProtocol(references: Set<Reference>, inherited: Set<String>)
        case redundantPublicAccessibility(modules: Set<String>)
        case superfluousIgnoreCommand
    }

    let declaration: Declaration
    let annotation: Annotation
    public let confidence: Confidence
    /// Why `confidence` is `likely`; nil when `certain`.
    public let confidenceReason: String?
    /// Why the declaration is reported, in one sentence.
    public let reason: String

    init(declaration: Declaration, annotation: Annotation, confidence: Confidence = .certain, confidenceReason: String? = nil, reason: String = "") {
        self.declaration = declaration
        self.annotation = annotation
        self.confidence = confidence
        self.confidenceReason = confidenceReason
        self.reason = reason
    }

    public var usrs: Set<String> {
        if case .superfluousIgnoreCommand = annotation {
            return declaration.usrs.mapSet { "superfluous-ignore-\($0)" }
        }
        return declaration.usrs
    }
}

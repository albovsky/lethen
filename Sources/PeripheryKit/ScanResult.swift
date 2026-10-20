import Foundation
import SourceGraph

public struct ScanResult {
    enum Annotation {
        case unused
        case assignOnlyProperty
        case redundantProtocol(references: Set<Reference>, inherited: Set<String>)
        case redundantPublicAccessibility(modules: Set<String>)
        case superfluousIgnoreCommand
        case unconstructedEnumCase
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

    /// What a result reports, for summaries. The last two are not dead code: the declaration stays, and only its
    /// access level or its comment changes.
    public enum Kind: CaseIterable {
        case unused
        case assignOnlyProperty
        case redundantProtocol
        case unconstructedEnumCase
        case redundantPublicAccessibility
        case superfluousIgnoreCommand

        /// The words a summary counts the kind with, as in "3 unused".
        public var summaryName: String {
            switch self {
            case .unused: "unused"
            case .assignOnlyProperty: "assign-only"
            case .redundantProtocol: "redundant protocol"
            case .unconstructedEnumCase: "unconstructed enum case"
            case .redundantPublicAccessibility: "redundant public"
            case .superfluousIgnoreCommand: "superfluous ignore"
            }
        }

        public var isDeadCode: Bool {
            self != .redundantPublicAccessibility && self != .superfluousIgnoreCommand
        }
    }

    public var kind: Kind {
        switch annotation {
        case .unused: .unused
        case .assignOnlyProperty: .assignOnlyProperty
        case .redundantProtocol: .redundantProtocol
        case .unconstructedEnumCase: .unconstructedEnumCase
        case .redundantPublicAccessibility: .redundantPublicAccessibility
        case .superfluousIgnoreCommand: .superfluousIgnoreCommand
        }
    }

    public var usrs: Set<String> {
        if case .superfluousIgnoreCommand = annotation {
            return declaration.usrs.mapSet { "superfluous-ignore-\($0)" }
        }
        return declaration.usrs
    }
}

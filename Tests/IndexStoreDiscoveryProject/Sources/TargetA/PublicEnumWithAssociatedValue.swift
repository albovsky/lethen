import ExternalTarget

public enum PublicEnumWithAssociatedValue: ExternalProtocol {
    case number(Int)

    public var value: Int {
        switch self {
        case let .number(value): value
        }
    }
}

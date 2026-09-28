enum FixtureEnum229: Equatable {
    case constructed
    case matchedOnly
    case comparedOnly
    case payloadMatchedOnly(Int)
}

// A case with the same name in another enum is constructed; that must not count for FixtureEnum229.
enum FixtureEnum229Other {
    case matchedOnly
}

// Control: a raw-value enum can construct any case through init(rawValue:).
enum FixtureEnum229Raw: String {
    case constructed = "c"
    case matchedOnly = "m"
}

// Control: CaseIterable can produce every case through allCases.
enum FixtureEnum229Iterable: CaseIterable {
    case constructed
    case matchedOnly
}

// Control: a public enum's cases can be constructed by clients outside the scan (--retain-public).
public enum FixtureEnum229Public {
    case constructed
    case matchedOnly
}

public class FixtureClass229Retainer {
    public func start(_ publicValue: FixtureEnum229Public) {
        run(.constructed, FixtureEnum229Raw(rawValue: "m") ?? .constructed, FixtureEnum229Iterable.allCases[0], publicValue)
    }

    func run(_ value: FixtureEnum229, _ raw: FixtureEnum229Raw, _ iterable: FixtureEnum229Iterable, _ publicValue: FixtureEnum229Public) {
        switch value {
        case .constructed, .matchedOnly, .comparedOnly:
            break
        case let .payloadMatchedOnly(number):
            _ = number
        }
        if case .matchedOnly = value {}
        _ = value == .comparedOnly
        if case .matchedOnly = raw {}
        if case .matchedOnly = iterable {}
        if case .matchedOnly = publicValue {}
        _ = FixtureEnum229Other.matchedOnly
    }
}

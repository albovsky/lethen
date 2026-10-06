import Foundation

public protocol FixtureProtocol321Endpoint {
    var jsonValue: Encodable? { get }
}

// Control: the unresolved value is the first argument of a callee whose `Encodable` parameter is the second, so
// it is not what the callee encodes.
struct FixtureStruct321Skipped: Encodable {
    let skippedValue: Int
}

struct FixtureStruct321SkippedEndpoint: FixtureProtocol321Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct321Skipped(skippedValue: 1)
    }
}

public class FixtureClass321SkippedSender {
    func emit(label: String, value: Encodable) {
        print(label)
        _ = value
    }

    public func send(endpoint: FixtureProtocol321Endpoint) {
        if let json = endpoint.jsonValue {
            emit(label: "\(json)", value: 1)
        }
    }

    public func retain() {
        send(endpoint: FixtureStruct321SkippedEndpoint())
    }
}

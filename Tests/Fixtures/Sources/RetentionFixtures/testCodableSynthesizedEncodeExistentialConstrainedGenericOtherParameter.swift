import Foundation

public protocol FixtureProtocol177Endpoint {
    var jsonValue: Encodable? { get }
}

// Control: the unresolved value is passed for a parameter that is not the constrained one.
struct FixtureStruct177Skipped: Encodable {
    let skippedGenericValue: Int
}

struct FixtureStruct177Endpoint: FixtureProtocol177Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct177Skipped(skippedGenericValue: 1)
    }
}

public class FixtureClass177Sender {
    func emit<T: Encodable>(label: String, value: T) {
        print(label)
        _ = value
    }

    public func send(endpoint: FixtureProtocol177Endpoint) {
        if let json = endpoint.jsonValue {
            emit(label: "\(json)", value: 1)
        }
    }

    public func retain() {
        send(endpoint: FixtureStruct177Endpoint())
    }
}

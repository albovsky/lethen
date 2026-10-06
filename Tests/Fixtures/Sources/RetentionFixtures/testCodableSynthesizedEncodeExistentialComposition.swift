import Foundation

public protocol FixtureProtocol322Endpoint {
    var jsonValue: (any Encodable & Sendable)? { get }
}

// The value reaches a parameter declared as a protocol composition, and it is not the first argument.
struct FixtureStruct322Composed: Encodable, Sendable {
    let composedValue: Int
}

struct FixtureStruct322Endpoint: FixtureProtocol322Endpoint {
    var jsonValue: (any Encodable & Sendable)? {
        FixtureStruct322Composed(composedValue: 1)
    }
}

public class FixtureClass322Sender {
    func emit(metadata: String, value: any Encodable & Sendable) {
        print(metadata)
        _ = value
    }

    public func send(endpoint: FixtureProtocol322Endpoint) {
        if let json = endpoint.jsonValue {
            emit(metadata: "m", value: json)
        }
    }

    public func retain() {
        send(endpoint: FixtureStruct322Endpoint())
    }
}

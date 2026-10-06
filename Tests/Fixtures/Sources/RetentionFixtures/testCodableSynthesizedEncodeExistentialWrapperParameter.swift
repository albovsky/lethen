import Foundation

public protocol FixtureProtocol320Endpoint {
    var jsonValue: Encodable? { get }
}

// The value reaches an `Encodable` parameter that is not the first argument; the first argument is a literal.
struct FixtureStruct320Wrapped: Encodable {
    let wrappedValue: Int
}

struct FixtureStruct320Endpoint: FixtureProtocol320Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct320Wrapped(wrappedValue: 1)
    }
}

public class FixtureClass320Sender {
    func emit(metadata: String, value: Encodable) {
        print(metadata)
        _ = value
    }

    public func send(endpoint: FixtureProtocol320Endpoint) {
        if let json = endpoint.jsonValue {
            emit(metadata: "m", value: json)
        }
    }

    public func retain() {
        send(endpoint: FixtureStruct320Endpoint())
    }
}

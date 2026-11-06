import Foundation

public protocol FixtureProtocol176Endpoint {
    var jsonValue: Encodable? { get }
}

// The value reaches a parameter typed by a generic parameter constrained to `Encodable`; the first argument is a
// literal.
struct FixtureStruct176Generic: Encodable {
    let genericValue: Int
}

struct FixtureStruct176Endpoint: FixtureProtocol176Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct176Generic(genericValue: 1)
    }
}

public class FixtureClass176Sender {
    func emit<T: Encodable>(metadata: String, value: T) {
        print(metadata)
        _ = value
    }

    public func send(endpoint: FixtureProtocol176Endpoint) {
        if let json = endpoint.jsonValue {
            emit(metadata: "m", value: json)
        }
    }

    public func retain() {
        send(endpoint: FixtureStruct176Endpoint())
    }
}

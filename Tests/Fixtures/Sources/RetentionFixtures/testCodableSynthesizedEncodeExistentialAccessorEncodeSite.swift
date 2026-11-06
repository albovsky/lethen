import Foundation

public protocol FixtureProtocol334Endpoint {
    var jsonValue: Encodable? { get }
}

// Produced as `Encodable?`, and an encoder in the getter of a used property receives a value of unknown type.
struct FixtureStruct334Mute: Encodable {
    let duration: Int
}

struct FixtureStruct334MuteEndpoint: FixtureProtocol334Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct334Mute(duration: 5)
    }
}

public class FixtureClass334Sender {
    let endpoint: FixtureProtocol334Endpoint = FixtureStruct334MuteEndpoint()

    public var payload: Data? {
        if let json = endpoint.jsonValue {
            return try? JSONEncoder().encode(json)
        }
        return nil
    }
}

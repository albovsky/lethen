import Foundation

public protocol FixtureProtocol178Endpoint {
    var jsonValue: Encodable { get }
}

// An element of a collection of `Encodable` existentials reaches an encoder.
struct FixtureStruct178Element: Encodable {
    let elementValue: Int
}

struct FixtureStruct178Endpoint: FixtureProtocol178Endpoint {
    var jsonValue: Encodable {
        FixtureStruct178Element(elementValue: 1)
    }
}

public class FixtureClass178Sender {
    public func send(endpoints: [FixtureProtocol178Endpoint]) throws -> Data {
        let values: [any Encodable] = endpoints.map(\.jsonValue)
        return try JSONEncoder().encode(values[0])
    }

    public func retain() throws -> Data {
        try send(endpoints: [FixtureStruct178Endpoint()])
    }
}

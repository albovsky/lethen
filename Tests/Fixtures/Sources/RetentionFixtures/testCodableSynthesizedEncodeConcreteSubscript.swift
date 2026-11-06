import Foundation

public protocol FixtureProtocol179Endpoint {
    var jsonValue: Encodable { get }
}

// Control: the encoder receives an element of an array of integers, so no encoder receives an opaque value.
struct FixtureStruct179Element: Encodable {
    let unencodedElementValue: Int
}

struct FixtureStruct179Endpoint: FixtureProtocol179Endpoint {
    var jsonValue: Encodable {
        FixtureStruct179Element(unencodedElementValue: 1)
    }
}

public class FixtureClass179Sender {
    public func send(endpoint: FixtureProtocol179Endpoint) throws -> Data {
        _ = endpoint.jsonValue
        let numbers = [1, 2]
        return try JSONEncoder().encode(numbers[0])
    }

    public func retain() throws -> Data {
        try send(endpoint: FixtureStruct179Endpoint())
    }
}

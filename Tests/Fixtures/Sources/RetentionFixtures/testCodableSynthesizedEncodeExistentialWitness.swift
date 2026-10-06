import Foundation

public protocol FixtureProtocol316Endpoint {
    var jsonValue: Encodable? { get }
}

// Produced as `Encodable?` by a witness, and an encoder receives a value whose type is a local bound from the
// protocol requirement, so the type is erased and the flow cannot be followed.
struct FixtureStruct316Mute: Encodable {
    let duration: Int
    // Control: read in code, so it is not assign-only.
    let readNormally: Int
}

struct FixtureStruct316MuteEndpoint: FixtureProtocol316Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct316Mute(duration: 5, readNormally: 6)
    }
}

// Reached through the existential value's own stored property, so its properties are as uncertain.
struct FixtureStruct316Nested: Encodable {
    let nestedDuration: Int
}

struct FixtureStruct316Outer: Encodable {
    let nested: FixtureStruct316Nested
}

struct FixtureStruct316OuterEndpoint: FixtureProtocol316Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct316Outer(nested: FixtureStruct316Nested(nestedDuration: 1))
    }
}

// Reached through an enum payload that the witness returns as a pattern-bound local.
struct FixtureStruct316Payload: Encodable {
    let payloadDuration: Int
}

enum FixtureEnum316Request: FixtureProtocol316Endpoint {
    case mute(FixtureStruct316Payload)

    var jsonValue: Encodable? {
        switch self {
        case let .mute(payload): payload
        }
    }
}

// Control: encoded directly, so the synthesized encoder is known to read it.
struct FixtureStruct316Direct: Encodable {
    let directlyEncoded: Int
}

// Control: Encodable but never produced as an existential and never encoded, so it stays certain.
struct FixtureStruct316Unrelated: Encodable {
    let unrelatedNotEncoded: Int
}

public class FixtureClass316Sender {
    public func send(endpoint: FixtureProtocol316Endpoint) throws -> Data? {
        if let json = endpoint.jsonValue {
            return try JSONEncoder().encode(json)
        }
        return nil
    }

    public func retain() throws {
        _ = try send(endpoint: FixtureStruct316MuteEndpoint())
        _ = try send(endpoint: FixtureStruct316OuterEndpoint())
        _ = try send(endpoint: FixtureEnum316Request.mute(FixtureStruct316Payload(payloadDuration: 1)))
        _ = try JSONEncoder().encode(FixtureStruct316Direct(directlyEncoded: 1))
        let mute = FixtureStruct316Mute(duration: 1, readNormally: 2)
        print(mute.readNormally)
        _ = FixtureStruct316Unrelated(unrelatedNotEncoded: 1)
    }
}

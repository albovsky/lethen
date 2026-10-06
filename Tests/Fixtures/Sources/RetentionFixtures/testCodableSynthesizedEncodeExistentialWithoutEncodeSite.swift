import Foundation

protocol FixtureProtocol317Endpoint {
    var jsonValue: Encodable? { get }
}

// Produced as `Encodable?`, but no encoder receives a value of unknown type in this file, so nothing suggests the
// synthesized encoder reads it and it stays certain.
struct FixtureStruct317Mute: Encodable {
    let duration: Int
}

struct FixtureStruct317MuteEndpoint: FixtureProtocol317Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct317Mute(duration: 5)
    }
}

public class FixtureClass317Sender {
    public func retain() throws {
        _ = FixtureStruct317MuteEndpoint().jsonValue
        // Encoders that receive a literal or a value of a known type are not opaque encode sites.
        _ = try JSONEncoder().encode(5)
        _ = try JSONEncoder().encode("text")
    }
}

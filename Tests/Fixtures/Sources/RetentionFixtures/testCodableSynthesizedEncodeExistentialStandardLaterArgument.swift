import Foundation

protocol FixtureProtocol332Endpoint {
    var jsonValue: Encodable? { get }
}

// Produced as `Encodable?`, but the only value of unknown type reaching an encoder is a container's key, which the
// standard `encode(_:forKey:)` does not encode, so nothing suggests the synthesized encoder reads it.
struct FixtureStruct332Mute: Encodable {
    let duration: Int
}

struct FixtureStruct332MuteEndpoint: FixtureProtocol332Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct332Mute(duration: 5)
    }
}

// Encoded directly, so its own property is read.
struct FixtureStruct332Item: Encodable {
    let itemEncoded: Int
}

struct FixtureStruct332Envelope: Encodable {
    enum CodingKeys: String, CodingKey {
        case first
        case second
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        for key in [CodingKeys.first, .second] {
            try container.encode(FixtureStruct332Item(itemEncoded: 1), forKey: key)
        }
    }
}

public class FixtureClass332Sender {
    public func retain() throws {
        _ = FixtureStruct332MuteEndpoint().jsonValue
        _ = try JSONEncoder().encode(FixtureStruct332Envelope())
    }
}

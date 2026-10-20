import Foundation

public protocol FixtureProtocol333Endpoint {
    var jsonValue: Encodable? { get }
}

// Produced as `Encodable?`, but the only encoder that receives a value of unknown type is in a private function
// nothing calls, so nothing suggests the synthesized encoder reads it and it stays certain.
struct FixtureStruct333Mute: Encodable {
    let duration: Int
    // Control: read in code, so it is not assign-only.
    let readNormally: Int
}

struct FixtureStruct333MuteEndpoint: FixtureProtocol333Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct333Mute(duration: 5, readNormally: 6)
    }
}

public class FixtureClass333Sender {
    private func unusedSend(endpoint: FixtureProtocol333Endpoint) throws -> Data? {
        if let json = endpoint.jsonValue {
            return try JSONEncoder().encode(json)
        }
        return nil
    }

    public func retain() {
        _ = FixtureStruct333MuteEndpoint().jsonValue
        let mute = FixtureStruct333Mute(duration: 1, readNormally: 2)
        print(mute.readNormally)
    }
}

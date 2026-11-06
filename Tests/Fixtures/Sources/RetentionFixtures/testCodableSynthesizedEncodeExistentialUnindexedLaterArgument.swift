import ExternalModuleFixtures
import Foundation

public protocol FixtureProtocol331Endpoint {
    var jsonValue: Encodable? { get }
}

// Produced as `Encodable?`, and an encoder from another module receives a value of unknown type as its second
// argument, so the synthesized encoder may read it.
struct FixtureStruct331Mute: Encodable {
    let duration: Int
    // Control: read in code, so it is not assign-only.
    let readNormally: Int
}

struct FixtureStruct331MuteEndpoint: FixtureProtocol331Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct331Mute(duration: 5, readNormally: 6)
    }
}

public class FixtureClass331Sender {
    public func send(endpoint: FixtureProtocol331Endpoint) {
        if let json = endpoint.jsonValue {
            fixtureEmit331(metadata: "json", value: json)
        }
    }

    public func retain() {
        send(endpoint: FixtureStruct331MuteEndpoint())
        let mute = FixtureStruct331Mute(duration: 1, readNormally: 2)
        print(mute.readNormally)
    }
}

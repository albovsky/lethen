import Foundation

public protocol FixtureProtocol330Endpoint {
    var jsonValue: CustomStringConvertible? { get }
}

// Produced as an existential of the configured protocol, and an encoder that takes that protocol receives a value
// whose type is a local bound from the requirement, so the type is erased and the flow cannot be followed.
struct FixtureStruct330Mute: Encodable, CustomStringConvertible {
    let duration: Int
    // Control: read in code, so it is not assign-only.
    let readNormally: Int

    var description: String {
        "mute"
    }
}

struct FixtureStruct330MuteEndpoint: FixtureProtocol330Endpoint {
    var jsonValue: CustomStringConvertible? {
        FixtureStruct330Mute(duration: 5, readNormally: 6)
    }
}

public class FixtureClass330Sender {
    // The existential is the second argument, so it is found only by the configured name of its parameter type.
    func emit(label: String, value: CustomStringConvertible) {
        print(label, value)
    }

    public func send(endpoint: FixtureProtocol330Endpoint) {
        if let json = endpoint.jsonValue {
            emit(label: "json", value: json)
        }
    }

    public func retain() {
        send(endpoint: FixtureStruct330MuteEndpoint())
        let mute = FixtureStruct330Mute(duration: 1, readNormally: 2)
        print(mute.readNormally)
    }
}

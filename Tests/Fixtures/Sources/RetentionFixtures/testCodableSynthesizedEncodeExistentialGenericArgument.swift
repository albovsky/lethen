import Foundation

public protocol FixtureProtocol325Endpoint {
    var jsonValue: Encodable? { get }
}

// Control: `Phantom325` never stores its type parameter, so nothing encodes `FixtureStruct325Hidden`.
struct Phantom325<T: Encodable>: Encodable {
    let marker: Int
}

struct FixtureStruct325Hidden: Encodable {
    let hiddenValue: Int
}

struct FixtureStruct325Shown: Encodable {
    let shownValue: Int
}

struct FixtureStruct325Outer: Encodable {
    let phantom: Phantom325<FixtureStruct325Hidden>
    let direct: FixtureStruct325Shown

    // Not typed as an existential, so the endpoint below names only `FixtureStruct325Outer`.
    static func make() -> FixtureStruct325Outer {
        FixtureStruct325Outer(
            phantom: Phantom325<FixtureStruct325Hidden>(marker: 1),
            direct: FixtureStruct325Shown(shownValue: 1)
        )
    }
}

struct FixtureStruct325Endpoint: FixtureProtocol325Endpoint {
    var jsonValue: Encodable? {
        FixtureStruct325Outer.make()
    }
}

public class FixtureClass325Sender {
    public func send(endpoint: FixtureProtocol325Endpoint) {
        if let json = endpoint.jsonValue {
            _ = try? JSONEncoder().encode(json)
        }
    }

    public func retain() {
        send(endpoint: FixtureStruct325Endpoint())
    }
}

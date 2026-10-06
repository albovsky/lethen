import Foundation

// Decoded only because the call site's result type fixes the `Decodable` generic parameter of `load(path:)`.
struct FixtureStruct315Bound: Decodable {
    let boundDecoded: Int
}

struct FixtureStruct315Returned: Decodable {
    let returnedDecoded: Int
}

struct FixtureStruct315ReturnedExplicit: Decodable {
    let explicitDecoded: Int
}

struct FixtureStruct315Cast: Decodable {
    let castDecoded: Int
}

// Control: its generic function is unconstrained, so binding the result decodes nothing.
struct FixtureStruct315Unconstrained: Decodable {
    let unconstrainedNotDecoded: Int
}

// Control: the generic function decodes one parameter and returns another, so the result type is not decoded.
struct FixtureStruct315OtherParameter: Decodable {
    let otherNotDecoded: Int
}

// Control: no call binds it to a decoding generic function; its property is used normally.
struct FixtureStruct315Used: Decodable {
    let usedNormally: Int
}

public class FixtureClass315Retainer {
    public func retain() throws {
        let bound: FixtureStruct315Bound = try load(path: "bound")
        _ = bound
        _ = try returned()
        _ = try returnedExplicit()
        _ = try load(path: "cast") as FixtureStruct315Cast
        let unconstrained: FixtureStruct315Unconstrained = make()
        _ = unconstrained
        let other: FixtureStruct315OtherParameter = try pair(Int.self, path: "other")
        _ = other
        let used = FixtureStruct315Used(usedNormally: 1)
        print(used.usedNormally)
    }

    func load<T: Decodable>(path: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(path.utf8))
    }

    func returned() throws -> FixtureStruct315Returned {
        try load(path: "returned")
    }

    func returnedExplicit() throws -> FixtureStruct315ReturnedExplicit {
        return try load(path: "explicit")
    }

    func make<T>() -> T {
        fatalError()
    }

    func pair<T: Decodable, U>(_ type: T.Type, path: String) throws -> U {
        _ = try JSONDecoder().decode(type, from: Data(path.utf8))
        fatalError()
    }
}

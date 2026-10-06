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

// Control: the function returning it only contains a single-statement `if` whose call is not its return value,
// so the function's return type must not be treated as decoded.
struct FixtureStruct315NestedOwner: Decodable {
    let nestedNotDecoded: Int
}

struct FixtureStruct315NestedDecoded: Decodable {
    let nestedDecoded: Int
}

// Control: the inferred result is a generic wrapper that never stores its parameter, so the argument is not decoded.
struct FixtureStruct315PhantomHidden: Decodable {
    let phantomNotDecoded: Int
}

struct FixturePhantom315<T>: Decodable {
    let marker: Int
}

// The wrapper stores its parameter, so the argument is decoded with it.
struct FixtureStruct315WrappedShown: Decodable {
    let wrappedDecoded: Int
}

struct FixtureWrapper315<T: Decodable>: Decodable {
    let value: T
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
        _ = try nestedOwner(true)
        let phantom: FixturePhantom315<FixtureStruct315PhantomHidden> = try load(path: "phantom")
        _ = phantom
        let wrapper: FixtureWrapper315<FixtureStruct315WrappedShown> = try load(path: "wrapper")
        _ = wrapper
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

    @discardableResult
    func loadType<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data())
    }

    func nestedOwner(_ flag: Bool) throws -> FixtureStruct315NestedOwner {
        if flag {
            try loadType(FixtureStruct315NestedDecoded.self)
        }
        fatalError()
    }

    func make<T>() -> T {
        fatalError()
    }

    func pair<T: Decodable, U>(_ type: T.Type, path: String) throws -> U {
        _ = try JSONDecoder().decode(type, from: Data(path.utf8))
        fatalError()
    }
}

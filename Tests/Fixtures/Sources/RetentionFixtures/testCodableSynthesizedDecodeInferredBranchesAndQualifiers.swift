import Foundation

struct FixtureStruct278IfBody: Decodable {
    let ifBodyDecoded: Int
}

struct FixtureStruct278SwitchBody: Decodable {
    let switchBodyDecoded: Int
}

struct FixtureStruct278IfInitializer: Decodable {
    let ifInitializerDecoded: Int
}

// Control: the function returns this type, but the `if` expression initializes a binding of another type.
struct FixtureStruct278NotWhole: Decodable {
    let notWholeNotDecoded: Int
}

struct FixtureStruct278Bound: Decodable {
    let boundByIfDecoded: Int
}

// Control: a qualifier is not the decoded type.
struct FixtureStruct278Outer: Decodable {
    let outerNotDecoded: Int

    struct Model: Decodable {
        let qualifiedModelDecoded: Int
    }
}

// A generic qualifier keeps its arguments: the nested type stores the outer type's parameter.
struct FixtureGeneric278Outer<T: Decodable>: Decodable {
    let outerValue: T

    struct Model: Decodable {
        let modelValue: T
    }
}

struct FixtureStruct278Item: Decodable {
    let itemDecoded: Int
}

public class FixtureClass278Retainer {
    public func retain(_ flag: Bool, _ number: Int) throws {
        _ = try ifBody(flag)
        _ = try switchBody(number)
        let initialized: FixtureStruct278IfInitializer = if flag { try load(path: "a") } else { try load(path: "b") }
        _ = initialized
        _ = try notWhole(flag)
        let qualified: FixtureStruct278Outer.Model = try load(path: "qualified")
        _ = qualified
        _ = FixtureStruct278Outer(outerNotDecoded: 1)
        let generic: FixtureGeneric278Outer<FixtureStruct278Item>.Model = try load(path: "generic")
        _ = generic
    }

    func ifBody(_ flag: Bool) throws -> FixtureStruct278IfBody {
        if flag {
            try load(path: "a")
        } else if !flag {
            try load(path: "b")
        } else {
            try load(path: "c")
        }
    }

    func switchBody(_ number: Int) throws -> FixtureStruct278SwitchBody {
        switch number {
        case 0:
            try load(path: "zero")
        default:
            try load(path: "other")
        }
    }

    func notWhole(_ flag: Bool) throws -> FixtureStruct278NotWhole {
        let bound: FixtureStruct278Bound = if flag { try load(path: "a") } else { try load(path: "b") }
        _ = bound
        return FixtureStruct278NotWhole(notWholeNotDecoded: 1)
    }

    func load<T: Decodable>(path: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(path.utf8))
    }
}

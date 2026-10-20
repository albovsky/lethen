import Foundation

// A wrapper that stores its generic parameter, decoded with the standard containers spelled out.
struct FixtureWrapper277<T: Decodable>: Decodable {
    let value: T
}

struct FixtureStruct277ArrayElement: Decodable {
    let arrayElementDecoded: Int
}

struct FixtureStruct277OptionalElement: Decodable {
    let optionalElementDecoded: Int
}

struct FixtureStruct277DictionaryValue: Decodable {
    let dictionaryValueDecoded: Int
}

struct FixtureStruct277QualifiedElement: Decodable {
    let qualifiedElementDecoded: Int
}

struct FixtureStruct277ShorthandElement: Decodable {
    let shorthandElementDecoded: Int
}

// Control: the phantom wrapper does not store its parameter, so spelling out the container decodes nothing.
struct FixturePhantom277<T>: Decodable {
    let marker: Int
}

struct FixtureStruct277PhantomElement: Decodable {
    let phantomElementNotDecoded: Int
}

public class FixtureClass277Retainer {
    public func retain() throws {
        let array: FixtureWrapper277<Array<FixtureStruct277ArrayElement>> = try load(path: "array")
        let optional: FixtureWrapper277<Optional<FixtureStruct277OptionalElement>> = try load(path: "optional")
        let dictionary: FixtureWrapper277<Dictionary<String, FixtureStruct277DictionaryValue>> = try load(path: "dictionary")
        let qualified: FixtureWrapper277<Swift.Array<FixtureStruct277QualifiedElement>> = try load(path: "qualified")
        let shorthand: FixtureWrapper277<[FixtureStruct277ShorthandElement]> = try load(path: "shorthand")
        let phantom: FixturePhantom277<Array<FixtureStruct277PhantomElement>> = try load(path: "phantom")
        _ = (array, optional, dictionary, qualified, shorthand, phantom)
    }

    func load<T: Decodable>(path: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(path.utf8))
    }
}

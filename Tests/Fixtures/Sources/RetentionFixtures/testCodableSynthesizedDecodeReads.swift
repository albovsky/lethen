import Foundation

struct FixtureStruct312: Decodable {
    // Required by the synthesized init(from:) when a type reaches a decoder: not assign-only.
    let decoded: Int
    // A nested value is decoded too, so its properties are required as well.
    let nested: FixtureStruct312Nested
    // A default value does not make a decoded property optional.
    var withDefault: Int = 0
    // An initialized constant is never decoded, so nothing reads it and it is unused.
    let fixed = 7
}

struct FixtureStruct312Nested: Decodable {
    let nestedValue: Int
}

struct FixtureStruct312Codable: Codable {
    // Codable includes Decodable.
    let codableDecoded: Int
}

struct FixtureStruct312Generic: Decodable {
    // Its metatype is passed to an indexed function generic over Decodable.
    let genericDecoded: Int
}

struct FixtureStruct312Extension {
    let extensionDecoded: Int
}

extension FixtureStruct312Extension: Decodable {}

struct FixtureStruct312Keyed: Decodable {
    // Named by CodingKeys, so it is decoded.
    let kept: Int
    // Absent from CodingKeys, so it is not decoded.
    var skipped: Int = 0

    enum CodingKeys: String, CodingKey {
        case kept
    }
}

struct FixtureStruct312Undecoded: Decodable {
    // Control: no type reaches a decoder, so nothing requires it.
    let neverDecoded: Int
}

struct FixtureStruct312Optional: Decodable {
    // Control: an optional property is decoded with decodeIfPresent, so removing it changes nothing.
    let optionalDecoded: Int?
    var spelledOutOptional: Optional<Int>
    var implicitlyUnwrapped: Int!
}

struct FixtureStruct312Passed: Decodable {
    // Used-but-not-decoded control: its metatype reaches an indexed, unconstrained function.
    let passedButNotDecoded: Int
}

struct FixtureStruct312Printed: Decodable {
    // Control: an unindexed call that does not decode (print) is not evidence.
    let printedButNotDecoded: Int
}

struct FixtureStruct312Metadata: Decodable {
    // Control: its metatype goes to an unconstrained parameter of a call whose other parameter is Decodable.
    let metadataNotDecoded: Int
}

struct FixtureStruct312Placeholder: Decodable {
    let placeholderDecoded: Int
}

struct FixtureStruct312Where: Decodable {
    // Constrained by a where clause, passed by label past a defaulted parameter.
    let whereDecoded: Int
}

struct FixtureStruct312Custom: Decodable {
    // Control: an explicit init(from:) replaces the synthesized one, so its writes count normally.
    let notDecodedByCustom: Int

    init(from _: Decoder) throws {
        notDecodedByCustom = 0
    }
}

public class FixtureClass312Retainer {
    public func decode(_ data: Data) throws {
        _ = try JSONDecoder().decode(FixtureStruct312.self, from: data)
        _ = try JSONDecoder().decode(FixtureStruct312Codable.self, from: data)
        _ = try JSONDecoder().decode(FixtureStruct312Extension.self, from: data)
        _ = try JSONDecoder().decode(FixtureStruct312Keyed.self, from: data)
        _ = try JSONDecoder().decode(FixtureStruct312Optional.self, from: data)
        _ = try JSONDecoder().decode(FixtureStruct312Custom.self, from: data)
        load(FixtureStruct312Generic.self)
        mixed(FixtureStruct312Placeholder.self, metadata: FixtureStruct312Metadata.self)
        constrained(extra: 1, FixtureStruct312Where.self)
    }

    func mixed<D: Decodable, U>(_: D.Type, metadata _: U.Type) {}

    func constrained<D>(extra _: Int = 0, _: D.Type) where D: Decodable {}

    func load<T: Decodable>(_: T.Type) {}

    public func hold() {
        keep(FixtureStruct312Passed.self)
        print(FixtureStruct312Printed.self)
        _ = FixtureStruct312Undecoded.self
    }

    func keep<T>(_: T.Type) {}
}

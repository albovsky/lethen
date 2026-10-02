import Foundation

struct FixtureStruct226: Encodable {
    // Read by the synthesized encode(to:) when a value reaches an encoder: not assign-only.
    let encoded: Int
    // A nested value is encoded too, so its properties are read as well.
    let nested: FixtureStruct226Nested

    init(encoded: Int, nested: FixtureStruct226Nested) {
        self.encoded = encoded
        self.nested = nested
    }
}

struct FixtureStruct226Nested: Encodable {
    let nestedValue: Int

    init(nestedValue: Int) {
        self.nestedValue = nestedValue
    }
}

struct FixtureStruct226Codable: Codable {
    // Codable includes Encodable.
    let codableEncoded: Int

    init(codableEncoded: Int) {
        self.codableEncoded = codableEncoded
    }
}

struct FixtureStruct226Generic: Encodable {
    // Passed to an indexed function generic over Encodable.
    let genericEncoded: Int

    init(genericEncoded: Int) {
        self.genericEncoded = genericEncoded
    }
}

struct FixtureStruct226Existential: Encodable {
    // Passed to an indexed function taking `any Encodable`.
    let existentialEncoded: Int

    init(existentialEncoded: Int) {
        self.existentialEncoded = existentialEncoded
    }
}

struct FixtureStruct226Unencoded: Encodable {
    // Control: no value reaches an encoder, so nothing reads it.
    let neverEncoded: Int

    init(neverEncoded: Int) {
        self.neverEncoded = neverEncoded
    }
}

struct FixtureStruct226Passed: Encodable {
    // Used-but-not-encoded control: passed to an indexed, unconstrained function.
    let passedButNotEncoded: Int

    init(passedButNotEncoded: Int) {
        self.passedButNotEncoded = passedButNotEncoded
    }
}

struct FixtureStruct226Appended: Encodable {
    // Control: an unindexed call that does not encode (a collection append, print) is not evidence.
    let appendedButNotEncoded: Int

    init(appendedButNotEncoded: Int) {
        self.appendedButNotEncoded = appendedButNotEncoded
    }
}

struct FixtureStruct226Metatype: Encodable {
    // Control: its metatype rides beside an encoded value; a metatype is not an encoded value.
    let metatypeNotEncoded: Int

    init(metatypeNotEncoded: Int) {
        self.metatypeNotEncoded = metatypeNotEncoded
    }
}

struct FixtureStruct226Overload: Encodable {
    // An unrelated encode(to:) overload does not replace the synthesized encode(to: Encoder).
    let overloadEncoded: Int

    init(overloadEncoded: Int) {
        self.overloadEncoded = overloadEncoded
    }

    func encode(to path: String) -> String {
        path
    }
}

protocol FixtureProtocol226Default {
    static var defaultValue: Self { get }
}

struct FixtureStruct226Held: Encodable, FixtureProtocol226Default {
    // Encoded as the generic argument of a Box that stores it in an initialized constant.
    let heldEncoded: Int

    static var defaultValue: FixtureStruct226Held {
        FixtureStruct226Held(heldEncoded: 1)
    }
}

struct FixtureStruct226Box<T: Encodable & FixtureProtocol226Default>: Encodable {
    let value: T = .defaultValue
}

struct FixtureStruct226Outer: Encodable {
    let box: FixtureStruct226Box<FixtureStruct226Held>
}

struct FixtureStruct226Custom: Encodable {
    // Control: an explicit encode(to:) replaces the synthesized one, so nothing reads it.
    let notEncodedByCustom: Int

    init(notEncodedByCustom: Int) {
        self.notEncodedByCustom = notEncodedByCustom
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(0)
    }
}

public class FixtureClass226Retainer {
    public func encode() throws -> [Data] {
        try [
            JSONEncoder().encode(FixtureStruct226(encoded: 1, nested: FixtureStruct226Nested(nestedValue: 2))),
            JSONEncoder().encode(FixtureStruct226Codable(codableEncoded: 3)),
            JSONEncoder().encode(FixtureStruct226Outer(box: FixtureStruct226Box())),
            JSONEncoder().encode(FixtureStruct226Overload(overloadEncoded: 13)),
            JSONEncoder().encode(FixtureStruct226Custom(notEncodedByCustom: 4)),
            encodeGeneric(FixtureStruct226Generic(genericEncoded: 7)),
            encodeExistential(FixtureStruct226Existential(existentialEncoded: 8)),
        ]
    }

    func encodeGeneric<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    func encodeExistential(_ value: any Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }

    func send<E: Encodable, U>(_ value: E, metadata _: U.Type) throws -> Data {
        try JSONEncoder().encode(value)
    }

    public func sendMetadata() throws {
        _ = try send(FixtureStruct226Generic(genericEncoded: 11), metadata: FixtureStruct226Metatype.self)
        _ = FixtureStruct226Metatype(metatypeNotEncoded: 12)
    }

    public func hold() {
        _ = FixtureStruct226Unencoded(neverEncoded: 5)
        keep(FixtureStruct226Passed(passedButNotEncoded: 6))
        var list: [FixtureStruct226Appended] = []
        list.append(FixtureStruct226Appended(appendedButNotEncoded: 9))
        print(FixtureStruct226Appended(appendedButNotEncoded: 10))
        _ = list
    }

    func keep(_ value: FixtureStruct226Passed) {
        _ = value
    }
}

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

    public func hold() {
        _ = FixtureStruct226Unencoded(neverEncoded: 5)
        keep(FixtureStruct226Passed(passedButNotEncoded: 6))
    }

    func keep(_ value: FixtureStruct226Passed) {
        _ = value
    }
}

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

struct FixtureStruct312Initializer: Decodable {
    // Passed to a constrained generic initializer.
    let initializerDecoded: Int
}

struct FixtureStruct312Variadic: Decodable {
    let variadicDecoded: Int
}

struct FixtureStruct312VariadicOther: Decodable {
    let variadicOtherDecoded: Int
}

protocol FixtureProtocol312HasPayload {
    associatedtype Payload
}

struct FixtureStruct312Dependent: Decodable, FixtureProtocol312HasPayload {
    // Control: only its associated Payload is constrained to Decodable by the helper it reaches, not the type itself.
    typealias Payload = Int

    let dependentNotDecoded: Int
}

struct FixtureStruct312Loader {
    init<T: Decodable>(_: T.Type) {}
}

struct FixtureStruct312Boxed: Decodable {
    // Control: only an element of a generic wrapper is constrained, not the wrapper's own parameter.
    let boxedNotDecoded: Int
}

struct FixtureStruct312Box<T: Decodable>: Decodable {
    let value: T
}

struct FixtureStruct312ValueOnly: Decodable {
    // Control: a value passed for a Decodable parameter has already been decoded; only a metatype decodes.
    let valueNotDecoded: Int
}

struct FixtureStruct312Composed: Decodable {
    // Passed as the metatype of a protocol composition.
    let composedDecoded: Int
}

typealias FixtureAlias312 = Decodable

struct FixtureStruct312Aliased: Decodable {
    // Control: a typealias to Decodable is not recognized, so it is not evidence.
    let aliasedNotDecoded: Int
}

public struct FixtureStruct312Key: CodingKey, Decodable {
    // Control: an external decoding call decodes only its metatype argument, not the key passed beside it.
    public let stringValue: String
    public let intValue: Int? = nil
    let keyNotDecoded: Int

    public init?(stringValue: String) {
        self.stringValue = stringValue
        keyNotDecoded = 0
    }

    public init?(intValue _: Int) {
        nil
    }
}

struct FixtureStruct312Lazy: Decodable {
    let lazyAnchor: Int
    // The synthesized initializer does not decode a lazy property. Lethen never reports one as assign-only, so this
    // is not observable in the results; the rule only keeps the model from inventing reads.
    lazy var lazyNotDecoded = 0
}

struct FixtureStruct312Holder: Decodable {
    // Control: optional, so decoded with decodeIfPresent and not required itself.
    let child: FixtureStruct312Child?
}

struct FixtureStruct312Child: Decodable {
    // Retained: decodeIfPresent still runs Child's synthesized initializer when the key is present.
    let childRequired: Int
}

struct FixtureStruct312Page<Value: Decodable>: Decodable {
    let items: [Value]
    let total: Int
}

struct FixtureStruct312Item: Decodable {
    // Decoded as the generic argument of a decoded Page.
    let itemDecoded: Int
}

struct FixtureStruct312Phantom<Tag>: Decodable {
    // Never stores a Tag, so decoding a Phantom decodes no Tag.
    let count: Int
}

struct FixtureStruct312Tag: Decodable {
    // Control: only the phantom parameter of a decoded generic names it.
    let tagNotDecoded: Int
}

struct FixtureStruct312Envelope<Value>: Decodable {
    // Stores the parameter only inside another generic wrapper, which this rule does not follow.
    let wrapped: FixtureStruct312Phantom<Value>
}

struct FixtureStruct312Nested2: Decodable {
    // Control: reached only through Phantom<T> inside a decoded Envelope<T>.
    let nested2NotDecoded: Int
}

struct FixtureStruct312Dictionary<Value: Decodable>: Decodable {
    let table: [String: Value]
}

struct FixtureStruct312Entry: Decodable {
    let entryDecoded: Int
}

struct FixtureStruct312Overload: Decodable {
    // An unrelated init(from:) overload does not replace the synthesized init(from: Decoder).
    let overloadDecoded: Int

    init(from number: Int) {
        overloadDecoded = number
    }
}

struct FixtureStruct312LabeledA: Decodable {
    let labeledADecoded: Int
}

struct FixtureStruct312LabeledB: Decodable {
    let labeledBDecoded: Int
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
        _ = FixtureStruct312Loader(FixtureStruct312Initializer.self)
        variadic(FixtureStruct312Variadic.self, FixtureStruct312Variadic.self)
        variadicMixed(FixtureStruct312Variadic.self, FixtureStruct312VariadicOther.self)
        inspect(FixtureStruct312Dependent.self)
        boxed(makeBox())
        valueOnly(FixtureStruct312ValueOnly(valueNotDecoded: 2))
        composed(FixtureStruct312Composed.self)
        aliased(FixtureStruct312Aliased.self)
        _ = try JSONDecoder().decode(FixtureStruct312Lazy.self, from: data)
        _ = try JSONDecoder().decode(FixtureStruct312Holder.self, from: data)
        _ = try JSONDecoder().decode(FixtureStruct312Page<FixtureStruct312Item>.self, from: data)
        _ = try JSONDecoder().decode(FixtureStruct312Phantom<FixtureStruct312Tag>.self, from: data)
        _ = FixtureStruct312Tag(tagNotDecoded: 1)
        _ = try JSONDecoder().decode(FixtureStruct312Envelope<FixtureStruct312Nested2>.self, from: data)
        _ = FixtureStruct312Nested2(nested2NotDecoded: 1)
        _ = try JSONDecoder().decode(FixtureStruct312Dictionary<FixtureStruct312Entry>.self, from: data)
        _ = try JSONDecoder().decode(FixtureStruct312Overload.self, from: data)
        labeled(types: FixtureStruct312LabeledA.self, FixtureStruct312LabeledB.self)
    }

    func variadic<T: Decodable>(_: T.Type...) {}

    func labeled(types _: any Decodable.Type...) {}

    func boxed<T: Decodable>(_: FixtureStruct312Box<T>) {}

    func makeBox() -> FixtureStruct312Box<FixtureStruct312Boxed> { fatalError() }

    func valueOnly<T: Decodable>(_: T) {}

    func composed(_: any (Decodable & Sendable).Type) {}

    func aliased(_: any FixtureAlias312.Type) {}

    public func read(_ container: KeyedDecodingContainer<FixtureStruct312Key>, key: FixtureStruct312Key) throws {
        _ = try container.decode([Int].self, forKey: key)
    }

    func variadicMixed(_: any Decodable.Type...) {}

    func inspect<T: FixtureProtocol312HasPayload>(_: T.Type) where T.Payload: Decodable {}

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

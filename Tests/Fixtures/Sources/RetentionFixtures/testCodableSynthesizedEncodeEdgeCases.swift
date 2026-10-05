import Foundation

struct FixtureStruct227Keyed: Encodable {
    let listed: Int
    // Omitted by CodingKeys, so the synthesized encoder never reads it.
    let omitted: Int

    enum CodingKeys: String, CodingKey {
        case listed
    }

    init(listed: Int, omitted: Int) {
        self.listed = listed
        self.omitted = omitted
    }
}

final class FixtureClass227Keyed: Encodable {
    let listed: Int
    let omitted: Int

    enum CodingKeys: String, CodingKey {
        case listed
    }

    init(listed: Int, omitted: Int) {
        self.listed = listed
        self.omitted = omitted
    }
}

struct FixtureStruct227Plain: Encodable {
    // Control: no CodingKeys and no custom encoder, so it is read.
    let plain: Int

    init(plain: Int) {
        self.plain = plain
    }
}

final class FixtureClass227Plain: Encodable {
    let plain: Int

    init(plain: Int) {
        self.plain = plain
    }
}

class FixtureClass227PrivateBase {
    // Not inherited: a subclass cannot see it, so it is not the witness.
    private func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(0)
    }
}

final class FixtureClass227PrivateSub: FixtureClass227PrivateBase, Encodable {
    // Synthesized, so the property is read.
    let synthesized: Int

    init(synthesized: Int) {
        self.synthesized = synthesized
    }
}

class FixtureClass227InternalBase {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(0)
    }
}

final class FixtureClass227InternalSub: FixtureClass227InternalBase, Encodable {
    // Pinned: the inherited internal encode(to:) is the witness, so nothing reads it.
    let inherited: Int

    init(inherited: Int) {
        self.inherited = inherited
    }
}

protocol FixtureProtocol227Encoder: Encodable {}

extension FixtureProtocol227Encoder {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(0)
    }
}

struct FixtureStruct227Witness: FixtureProtocol227Encoder {
    // The protocol extension supplies the witness, so nothing is synthesized and nothing reads it.
    let viaExtension: Int

    init(viaExtension: Int) {
        self.viaExtension = viaExtension
    }
}

final class FixtureClass227Witness: FixtureProtocol227Encoder {
    let viaExtension: Int

    init(viaExtension: Int) {
        self.viaExtension = viaExtension
    }
}

protocol FixtureProtocol227Plain: Encodable {}

struct FixtureStruct227PlainConforming: FixtureProtocol227Plain {
    // Control: the protocol has no encode(to:) extension, so the encoder is synthesized.
    let conformed: Int

    init(conformed: Int) {
        self.conformed = conformed
    }
}

fileprivate class FixtureClass227FilePrivateBase {
    fileprivate func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(0)
    }
}

fileprivate final class FixtureClass227FilePrivateSub: FixtureClass227FilePrivateBase, Encodable {
    // Same file: the fileprivate encode(to:) is inherited and is the witness, so nothing reads it.
    let inheritedInFile: Int

    init(inheritedInFile: Int) {
        self.inheritedInFile = inheritedInFile
    }
}

protocol FixtureProtocol227Marker {}

extension FixtureProtocol227Plain where Self: FixtureProtocol227Marker {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(0)
    }
}

struct FixtureStruct227Unmarked: FixtureProtocol227Plain {
    // The constrained extension does not apply: the encoder is synthesized.
    let unmarked: Int

    init(unmarked: Int) {
        self.unmarked = unmarked
    }
}

struct FixtureStruct227Marked: FixtureProtocol227Plain, FixtureProtocol227Marker {
    // The constrained extension applies, so nothing is synthesized and nothing reads it.
    let marked: Int

    init(marked: Int) {
        self.marked = marked
    }
}

fileprivate class FixtureClass227Mid: FixtureClass227FilePrivateBase {}

fileprivate final class FixtureClass227Concrete: FixtureClass227Mid, Encodable {
    // Same file as the fileprivate base: inherited through Mid, so it is the witness and nothing reads it.
    let throughMid: Int

    init(throughMid: Int) {
        self.throughMid = throughMid
    }
}

class FixtureClass227Base {}

protocol FixtureProtocol227ClassConstrained: Encodable {}

extension FixtureProtocol227ClassConstrained where Self: FixtureClass227Base {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(0)
    }
}

struct FixtureStruct227ClassConstrained: FixtureProtocol227ClassConstrained {
    // The extension needs a FixtureClass227Base, which a struct is not, so the encoder is synthesized.
    let classConstrained: Int

    init(classConstrained: Int) {
        self.classConstrained = classConstrained
    }
}

protocol FixtureProtocol227Static: Encodable {}

extension FixtureProtocol227Static {
    static func encode(to encoder: Encoder) throws {}
}

struct FixtureStruct227Static: FixtureProtocol227Static {
    // A static overload is not the witness, so the encoder is synthesized.
    let staticOverload: Int

    init(staticOverload: Int) {
        self.staticOverload = staticOverload
    }
}

final class FixtureClass227Read {
    // Used-but-not-encoded control: read normally in a type that is never encoded.
    var readNormally: Int = 0

    func value() -> Int {
        readNormally
    }
}

public final class FixtureClass227EdgeRetainer {
    private let read = FixtureClass227Read()

    public init() {}

    public func encode() throws -> [Data] {
        _ = read.value()
        return try [
            JSONEncoder().encode(FixtureStruct227Keyed(listed: 1, omitted: 2)),
            JSONEncoder().encode(FixtureClass227Keyed(listed: 3, omitted: 4)),
            JSONEncoder().encode(FixtureStruct227Plain(plain: 5)),
            JSONEncoder().encode(FixtureClass227Plain(plain: 6)),
            JSONEncoder().encode(FixtureClass227PrivateSub(synthesized: 7)),
            JSONEncoder().encode(FixtureClass227InternalSub(inherited: 8)),
            JSONEncoder().encode(FixtureStruct227Witness(viaExtension: 9)),
            JSONEncoder().encode(FixtureClass227Witness(viaExtension: 10)),
            JSONEncoder().encode(FixtureStruct227PlainConforming(conformed: 11)),
            JSONEncoder().encode(FixtureClass227FilePrivateSub(inheritedInFile: 12)),
            JSONEncoder().encode(FixtureStruct227Unmarked(unmarked: 13)),
            JSONEncoder().encode(FixtureStruct227Marked(marked: 14)),
            JSONEncoder().encode(FixtureClass227Concrete(throughMid: 15)),
            JSONEncoder().encode(FixtureStruct227ClassConstrained(classConstrained: 16)),
            JSONEncoder().encode(FixtureStruct227Static(staticOverload: 17)),
        ]
    }
}

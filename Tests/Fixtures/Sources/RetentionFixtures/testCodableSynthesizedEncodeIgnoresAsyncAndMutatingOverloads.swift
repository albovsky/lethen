import Foundation

class FixtureClass152AsyncBase {
    func encode(to _: Encoder) async throws {}
}

final class FixtureClass152AsyncSub: FixtureClass152AsyncBase, Encodable {
    // The inherited async encode(to:) cannot witness the requirement, so the encoder is synthesized and reads it.
    let viaAsyncOverload: Int

    init(viaAsyncOverload: Int) {
        self.viaAsyncOverload = viaAsyncOverload
    }
}

class FixtureClass152SyncBase {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(0)
    }
}

final class FixtureClass152SyncSub: FixtureClass152SyncBase, Encodable {
    // Control: the inherited synchronous encode(to:) is the witness, so nothing reads it.
    let viaSyncWitness: Int

    init(viaSyncWitness: Int) {
        self.viaSyncWitness = viaSyncWitness
    }
}

protocol FixtureProtocol152Mutating: Encodable {}

extension FixtureProtocol152Mutating {
    mutating func encode(to _: Encoder) throws {}
}

struct FixtureStruct152Mutating: FixtureProtocol152Mutating {
    // The extension's mutating encode(to:) cannot witness the requirement, so the encoder is synthesized.
    let viaMutatingOverload: Int

    init(viaMutatingOverload: Int) {
        self.viaMutatingOverload = viaMutatingOverload
    }
}

protocol FixtureProtocol152Async: Encodable {}

extension FixtureProtocol152Async {
    func encode(to _: Encoder) async throws {}
}

struct FixtureStruct152Async: FixtureProtocol152Async {
    // The extension's async encode(to:) cannot witness the requirement, so the encoder is synthesized.
    let viaAsyncExtension: Int

    init(viaAsyncExtension: Int) {
        self.viaAsyncExtension = viaAsyncExtension
    }
}

struct FixtureStruct152NotEncoded: FixtureProtocol152Mutating {
    // Used-but-not-encoded control: the encoder is synthesized, but no value reaches an encoder.
    let neverEncoded: Int

    init(neverEncoded: Int) {
        self.neverEncoded = neverEncoded
    }
}

public final class FixtureClass152Retainer {
    public init() {}

    public func encode() throws -> [Data] {
        _ = FixtureStruct152NotEncoded(neverEncoded: 0)
        return try [
            JSONEncoder().encode(FixtureClass152AsyncSub(viaAsyncOverload: 1)),
            JSONEncoder().encode(FixtureClass152SyncSub(viaSyncWitness: 2)),
            JSONEncoder().encode(FixtureStruct152Mutating(viaMutatingOverload: 3)),
            JSONEncoder().encode(FixtureStruct152Async(viaAsyncExtension: 4)),
        ]
    }
}

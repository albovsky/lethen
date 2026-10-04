import Foundation

// Encoded through a stored property of another type, as a class and as a struct.
final class FixtureClass226Stored: Encodable {
    // Assign-only in code; read by the synthesized encode(to:) when an instance reaches an encoder.
    var classStoredEncoded: Double?

    init() {}
}

struct FixtureStruct226Stored: Encodable {
    var structStoredEncoded: Double?
}

final class FixtureClass226Unencoded: Encodable {
    // Control: constructed and stored, but never reaches an encoder, so nothing reads it.
    var classNeverEncoded: Double?

    init() {}
}

class FixtureClass226Base: Encodable {
    var baseEncoded: Int = 0
}

final class FixtureClass226Sub: FixtureClass226Base {
    // Swift does not synthesize encode(to:) for a subclass of an Encodable class, so the property is not read.
    var subNotEncoded: Int?
}

final class FixtureClass226Read {
    // Used-but-not-encoded control: read normally, never encoded.
    var classReadNormally: Int = 0

    func value() -> Int {
        classReadNormally
    }
}

public final class FixtureClass226StoredRetainer {
    private var pages: [FixtureClass226Stored] = []
    private var items: [FixtureStruct226Stored] = []
    private var unencoded: [FixtureClass226Unencoded] = []
    private let read = FixtureClass226Read()

    public init() {}

    public func fill() {
        let page = FixtureClass226Stored()
        page.classStoredEncoded = 1.5
        pages.append(page)
        var item = FixtureStruct226Stored()
        item.structStoredEncoded = 2.5
        items.append(item)
        let other = FixtureClass226Unencoded()
        other.classNeverEncoded = 3.5
        unencoded.append(other)
        let sub = FixtureClass226Sub()
        sub.subNotEncoded = 4
        _ = sub
        _ = read.value()
    }

    public func encode() throws -> [Data] {
        try [JSONEncoder().encode(pages), JSONEncoder().encode(items), JSONEncoder().encode(FixtureClass226Sub())]
    }
}

import Foundation

// Control: a metatype read from a dictionary by subscript is passed to a decoder. The dictionary's key type is not
// decoded, so its field, which its custom equality and hashing leave out, stays assign-only.
struct FixtureStruct180Key: Decodable, Hashable {
    let id: Int
    let keyField: Int

    init(id: Int, keyField: Int) {
        self.id = id
        self.keyField = keyField
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct FixtureStruct180Payload: Decodable {
    let payloadField: Int
}

public class FixtureClass180Loader {
    public init() {}

    public func load(data: Data) throws {
        let key = FixtureStruct180Key(id: 1, keyField: 2)
        let types: [FixtureStruct180Key: FixtureStruct180Payload.Type] = [key: FixtureStruct180Payload.self]
        _ = try JSONDecoder().decode(types[key]!, from: data)
    }
}

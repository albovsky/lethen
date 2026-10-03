import Foundation

struct FixtureStruct313: CustomStringConvertible {
    // Decodable only when CustomStringConvertible is configured as an external Codable protocol.
    let externallyDecoded: Int

    var description: String {
        ""
    }
}

public class FixtureClass313Retainer {
    public func decode() {
        _ = FixtureStruct313(externallyDecoded: 1)
        load(FixtureStruct313.self)
    }

    func load<T: CustomStringConvertible>(_: T.Type) {}
}

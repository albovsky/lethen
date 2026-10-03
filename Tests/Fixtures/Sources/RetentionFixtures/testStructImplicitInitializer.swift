import Foundation

public struct FixtureStruct13_Codable: Codable {
    let assignOnly: Int
}

public struct FixtureStruct13_NotCodable {
    let assignOnly: Int
    let used: Int
}

public struct FixtureStruct13Retainer {
    public func retain() {
        // FixtureStruct13_Codable is not decoded here: a decoded Codable struct has its required
        // properties read by the synthesized init(from:); see testCodableSynthesizedDecodeReads.
        _ = FixtureStruct13_NotCodable(assignOnly: 0, used: 0).used
    }
}

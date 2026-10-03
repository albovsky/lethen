import Foundation

struct FixtureStruct314: Decodable {
    // Decoded by top-level code in main.swift, which has no declaration to attribute the read to.
    let topLevelDecoded: Int
}

struct FixtureStruct314Undecoded: Decodable {
    // Control: nothing, top-level or otherwise, decodes it.
    let topLevelNotDecoded: Int
}

public func fixture314() {
    _ = FixtureStruct314(topLevelDecoded: 1)
    _ = FixtureStruct314Undecoded(topLevelNotDecoded: 1)
}

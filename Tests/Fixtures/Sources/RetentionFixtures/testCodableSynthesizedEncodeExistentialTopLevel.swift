import Foundation

// Produced as an `Encodable` existential, and encoded only by top-level code in main.swift, which has no declaration
// to attribute the encode to, with a value whose type is erased.
struct FixtureStruct319Top: Encodable {
    let topLevelEncoded: Int
}

let fixture319Value: Encodable = FixtureStruct319Top(topLevelEncoded: 1)

public func fixture319() {
    _ = fixture319Value
}

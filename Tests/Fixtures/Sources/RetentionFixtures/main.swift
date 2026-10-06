import Foundation

// Top-level code: indexed by testCodableSynthesizedDecodeTopLevel alongside its fixture.
_ = try? JSONDecoder().decode(FixtureStruct314.self, from: Data())

// Top-level code: indexed by testCodableSynthesizedEncodeExistentialTopLevel alongside its fixture.
_ = try? JSONEncoder().encode(fixture319Value)

import Foundation

// Top-level code: indexed by testCodableSynthesizedDecodeTopLevel alongside its fixture.
_ = try? JSONDecoder().decode(FixtureStruct314.self, from: Data())

// Top-level code: indexed by testCodableSynthesizedEncodeExistentialTopLevel alongside its fixture.
if let value = fixture319Value {
    _ = try? JSONEncoder().encode(value)
}

// Top-level code: indexed by testCodableSynthesizedEncodeDirectTopLevel alongside its fixture.
_ = try? JSONEncoder().encode(FixtureStruct323Direct(directEncoded: 1))

import Foundation

/// Named like the standard container, but from another module: its `decode` is not the standard decoding call.
public struct FakeDecodingContainer {
    public init() {}

    public func decode<T: Decodable>(_: T.Type, forKey _: String) -> Int {
        0
    }
}

import Observation

@available(macOS 14.0, *)
@Observable
public final class FixtureClass326 {
    var readProperty = 0
    var neverUsedProperty = false
    var otherNeverUsedProperty = ""

    public init() {}

    public func use() -> Int {
        readProperty += 1
        return readProperty
    }
}

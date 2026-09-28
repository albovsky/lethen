import Observation

@available(macOS 14.0, *)
@Observable
final class FixtureClass227 {
    var name = ""
}

@available(macOS 14.0, *)
@Observable
final class FixtureClass227Used {
    var name = ""
}

@available(macOS 14.0, *)
public class FixtureClass227Retainer {
    public func use() -> String {
        FixtureClass227Used().name
    }
}

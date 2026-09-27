import Foundation

public class FixtureClass223 {
    func namedInLiteral() {}
    func namedInSelectorString() {}
    func notNamedAnywhere() {}

    public func use() {
        _ = "namedInLiteral"
        _ = "namedInSelectorString:"
    }
}

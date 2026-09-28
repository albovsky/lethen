import Foundation

public class FixtureClass223 {
    func namedInLiteral() {}
    func namedInSelectorString() {}
    func notNamedAnywhere() {}
    func namedInProse() {}

    public func use(namedParameter: Int) {
        _ = "namedInLiteral"
        _ = "namedInSelectorString:"
        _ = "a message that mentions namedInProse"
        _ = "namedParameter"
    }
}

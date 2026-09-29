import Foundation

public class FixtureClass223 {
    func namedInLiteral() {}
    func namedInSelectorString() {}
    func notNamedAnywhere() {}
    func namedInProse() {}

    public func use() {
        _ = "namedInLiteral"
        _ = "namedInSelectorString:"
        _ = "a message that mentions namedInProse"
        _ = "namedParameter"
        take(namedParameter: 0)
    }

    // Internal, so its unused parameter is reported under --retain-public.
    func take(namedParameter: Int) {}
}

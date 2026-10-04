import Foundation

public class FixtureClass223 {
    func namedInReflection() {}
    func namedInSelectorString() {}
    func namedInBareLiteral() {}
    func notNamedAnywhere() {}
    func namedInProse() {}
    func usedAndNamed() {}
    var comparedAgainstMirrorLabel = 0

    public func use() {
        lookUp(forKey: "namedInReflection")
        lookUp(forKey: "namedInSelectorString:")
        lookUp(forKey: "usedAndNamed")
        usedAndNamed()
        // A bare literal does not look anything up: a pure-Swift function it names is not downgraded.
        _ = "namedInBareLiteral"
        _ = "a message that mentions namedInProse"
        _ = "namedParameter"
        take(namedParameter: 0)
        _ = Mirror(reflecting: self).children.contains { $0.label == "comparedAgainstMirrorLabel" }
    }

    /// Stands in for `value(forKey:)`, which the rule reads by its argument label.
    func lookUp(forKey _: String) {}

    // Internal, so its unused parameter is reported under --retain-public.
    func take(namedParameter: Int) {}
}

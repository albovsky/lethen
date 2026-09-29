import Foundation

public class FixtureClass238: NSObject {
    // Retained: named in a selector, so the Objective-C runtime calls it with this signature.
    @objc func selectorTarget(_ unused: Any) {}

    // Reported: an Objective-C accessible method that is only called.
    @objc func calledTarget(unused: Any) {}

    public func register() -> Selector {
        calledTarget(unused: 0)
        return #selector(selectorTarget(_:))
    }
}

import Foundation

// Shadows the SDK's `CDouble`, so a bare `CDouble(...)` constructs this and no `Double`.
struct CDouble {}

extension Double {
    // A skipped `Swift.CDouble(fixtureQualified10:)` constructs the SDK's `CDouble`, a `Double`, and names this.
    init(fixtureQualified10 _: Substring) { self = 0 }
    // Control: a skipped bare `CDouble(fixtureBare10:)` constructs the scan's own `CDouble`.
    init(fixtureBare10 _: Substring) { self = 0 }
}

struct FixtureLocal10 {
    // A skipped `RetentionFixtures.FixtureLocal10(fixtureOwnModule10:)` is spelled through this type's own module.
    init(fixtureOwnModule10 _: Int) {}
    // Control: a skipped `Foundation.FixtureLocal10(fixtureOtherModule10:)` is another module's type of that name.
    init(fixtureOtherModule10 _: Int) {}
    // Used-but-not-compared control: called in the clause this build compiled.
    init(fixtureCompiled10 _: Int) {}
}

extension Substring {
    struct FixtureNested10 {
        // A skipped `Substring.FixtureNested10(fixtureNested10:)` reaches this type through the type the scan extends.
        init(fixtureNested10 _: Int) {}
        // A skipped `FixtureUnknown10.FixtureNested10(fixtureUnimported10:)` may reach this type through a type the
        // scan does not know, as `NSString.Widget` reaches a `Widget` declared in an extension of `NSObject`.
        init(fixtureUnimported10 _: Int) {}
    }
}

protocol FixtureConstructible10 {
    init()
}

extension Bool: FixtureConstructible10 {}

extension FixtureConstructible10 {
    // A skipped `Swift.Bool(fixtureProtocol10:)` reaches this through `Bool`'s conformance.
    init(fixtureProtocol10 _: Int) { self.init() }
}

public func fixtureQualifiedConstructions10() {
    _ = CDouble.self
    _ = Substring.FixtureNested10.self
    #if os(Windows)
        _ = Swift.CDouble(fixtureQualified10: Substring("1"))
        _ = CDouble(fixtureBare10: Substring("1"))
        _ = RetentionFixtures.FixtureLocal10(fixtureOwnModule10: 1)
        _ = Foundation.FixtureLocal10(fixtureOtherModule10: 1)
        _ = Substring.FixtureNested10(fixtureNested10: 1)
        _ = FixtureUnknown10.FixtureNested10(fixtureUnimported10: 1)
        _ = Swift.Bool(fixtureProtocol10: 1)
    #else
        _ = FixtureLocal10(fixtureCompiled10: 1)
    #endif
}

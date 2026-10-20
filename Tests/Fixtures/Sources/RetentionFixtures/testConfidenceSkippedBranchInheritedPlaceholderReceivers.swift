public protocol FixtureMarker7 {}

struct FixtureConformer7: FixtureMarker7 {
    // A skipped `Element(size: 1)` in an extension of `Array` constructs whatever `Element` is, which can be this.
    init(size _: Int) {}
    // A skipped `FixtureNamed7(label: 1)` constructs a type of the scan, which is not this one.
    init(label _: Int) {}
    // Used-but-not-compared control: called in the clause this build compiled.
    init(count _: Int) {}
}

struct FixtureNamed7 {
    init(label _: Int) {}
}

struct FixtureOther7 {
    // No skipped use spells these labels.
    init(weight _: Int) {}
}

extension Array where Element: FixtureMarker7 {
    public func fixtureBuild7() {
        _ = FixtureConformer7(count: 1)
        _ = FixtureNamed7.self
        _ = FixtureOther7.self
        #if os(Windows)
            _ = Element(size: 1)
            _ = FixtureNamed7(label: 1)
        #endif
    }
}

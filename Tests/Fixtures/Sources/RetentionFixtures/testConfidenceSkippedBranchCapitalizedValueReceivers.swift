public class FixtureStore8 {
    static let shared8 = FixtureStore8()
    // No skipped use names it.
    static let unnamed8 = 0
    // Used-but-not-compared control: read in the clause this build compiled.
    static let read8 = 0
}

class FixtureOtherStore8 {
    // A skipped `Store.shared8` through a value names no type, so it can be this one too.
    static let shared8 = FixtureOtherStore8()
}

class FixtureNarrowA8 {
    static let narrow8 = 0
}

class FixtureNarrowB8 {
    // Control: a skipped `FixtureNarrowA8.narrow8` is spelled through another type of the scan.
    static let narrow8 = 0
}

// `Store` is a capitalized parameter, not a type: the skipped `Store.shared8` reaches whatever it holds.
public func fixtureCapitalizedValue8(Store: FixtureStore8.Type) {
    _ = Store.read8
    _ = FixtureOtherStore8.self
    _ = FixtureNarrowA8.self
    _ = FixtureNarrowB8.self
    #if os(Windows)
        _ = Store.shared8
        _ = FixtureNarrowA8.narrow8
    #endif
}

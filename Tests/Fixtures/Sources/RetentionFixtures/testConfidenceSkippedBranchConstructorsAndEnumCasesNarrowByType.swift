import Foundation

struct FixtureWidget6 {
    init(size: Int) { Self.sizeHelper6() }
    init(name: String) { Self.nameHelper6() }
    // Called in the clause this build compiled, and spelled again in the skipped one: used.
    init(count: Int) {}
    init(never: Int) {}

    static func sizeHelper6() {}
    static func nameHelper6() {}
}

struct FixtureClosureWidget6 {
    init(body: () -> Void) {}
}

struct FixtureGadget6 {
    init(size: Int) {}
}

enum FixtureEnumA6 {
    case ready
    case go
    case patternOnly
}

enum FixtureEnumB6 {
    case ready
    case go
    case patternOnly
}

public func fixtureConstructors6() {
    let a: FixtureEnumA6? = nil
    let b: FixtureEnumB6? = nil
    _ = FixtureWidget6(count: 1)
    _ = FixtureWidget6.self
    _ = FixtureGadget6.self
    _ = FixtureClosureWidget6.self
    if let a {
        switch a {
        case .ready, .go, .patternOnly: break
        }
    }
    if let b {
        switch b {
        case .ready, .go, .patternOnly: break
        }
    }
    #if os(Windows)
        _ = FixtureWidget6(size: 1)
        _ = FixtureClosureWidget6 { }
        _ = FixtureWidget6(count: 2)
        _ = FixtureEnumA6.ready
        let go: FixtureEnumA6 = .go
        switch a {
        case .patternOnly?: break
        default: break
        }
    #endif
}

struct FixtureGenericTarget6 {
    init(tag: Int) {}
}

// `T` is a placeholder declared outside the skipped clause, so `T(tag: 1)` can construct any conforming type.
public func fixtureGeneric6<T>(_: T.Type) {
    _ = FixtureGenericTarget6.self
    #if os(Windows)
        _ = T(tag: 1)
    #endif
}

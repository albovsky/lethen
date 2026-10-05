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

// Initializers declared in extensions of types the scan does not declare, like a `UIColor` extension.
extension URL {
    // A skipped `String.init(data:encoding:)` constructs a `String`, which is not a `URL`, and does not spell these labels.
    init(fixtureHex6 _: Int) { self.init(string: "x")! }
    init(fixtureHex6 _: String, alpha _: Int) { self.init(string: "x")! }
    // A skipped `URL(fixtureTint6:)` names this one.
    init(fixtureTint6 _: Int) { self.init(string: "x")! }
    // A skipped `String.init(fixtureTint6:)` constructs a `String`: same labels, other type.
    init(fixtureOtherTint6 _: Int) { self.init(string: "x")! }
    // A skipped `FixtureLog6("x")` is a call of a function, `DDLogDebug("...")` in Wikipedia, and constructs no `URL`.
    init(_ fixtureSeed6: Int) { self.init(string: "x")! }
}

extension Int32 {
    // A skipped `CInt(...)` constructs an `Int32`: `CInt` is another name for it.
    init(_ fixtureSeed6: Substring) { self = 0 }
}

// Shadows the SDK's `CFloat`, so a skipped `CFloat(...)` constructs this and no `Float`.
struct CFloat {}

extension Float {
    init(_ fixtureSeed6: Substring) { self = 0 }
}

extension Double {
    // A skipped `TimeInterval(1)` constructs a `Double`: `TimeInterval` is another name for it.
    init(_ fixtureSeed6: Substring) { self = 0 }
}

public func fixtureExternalExtensions6() {
    #if os(Windows)
        _ = String.init(data: Data(), encoding: String.Encoding.utf8)
        _ = String(data: Data(), encoding: .utf8)
        _ = URL(fixtureTint6: 1)
        _ = String(fixtureOtherTint6: 1)
        FixtureLog6("x")
        _ = CInt(Substring("1"))
        _ = CFloat(Substring("1"))
        _ = TimeInterval(Substring("1"))
    #endif
}

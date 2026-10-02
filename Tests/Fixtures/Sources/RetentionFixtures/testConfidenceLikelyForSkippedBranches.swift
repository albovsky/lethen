import Foundation
#if os(Windows)
    import WinSDK
#endif

enum FixtureEnum312 {
    case constructed
    case constructedOnlyOnWindows
    case comparedInTakenBranch
    case matchedOnly
    case idle
    case windowsLoopOnly
}

typealias FixtureTypealias312 = Int
typealias FixtureTypealiasUnnamed312 = Int

enum FixtureEnum312Other {
    // Shares a name with a case constructed only on Windows: accepted as likely.
    case constructedOnlyOnWindows
}

public class FixtureClass312 {
    func calledOnlyOnWindows() {}
    func calledInTakenBranch() {}
    func neverNamed() {}
    // Named like a module imported only on Windows; import-only clauses are not evidence.
    func WinSDK() {}
    // Redeclared in the skipped branch below, which declares the name but does not use it.
    func redeclaredOnlyOnWindows() {}
    // A bare identifier in the skipped branch (a local) is not a use of a member.
    var shadowedByLocal = 0
    var overriddenLabel = 0

    func matchOther(_ value: FixtureEnum312Other?) {
        if case .constructedOnlyOnWindows? = value {}
    }

    public func use() {
        run(.constructed)
    }

    func run(_ value: FixtureEnum312) {
        switch value {
        case .constructed, .constructedOnlyOnWindows, .matchedOnly, .idle, .windowsLoopOnly: break
        case .comparedInTakenBranch: break
        }
        matchOther(nil)

        #if !os(Windows)
            _ = FixtureEnum312.constructed
            _ = value == .comparedInTakenBranch
            calledInTakenBranch()
        #endif

        #if os(Windows)
            let shadowedByLocal = 1
            _ = shadowedByLocal
            // A bare local is not a use of an enum case, and a `for case` pattern only matches it.
            let idle = value
            _ = idle
            for case .windowsLoopOnly in [value] {}
            let aliased: FixtureTypealias312 = 1
            _ = aliased
            _ = FixtureEnum312.constructedOnlyOnWindows
            calledOnlyOnWindows()
        #endif
    }
}

#if os(Windows)
    extension FixtureClass312 {
        func redeclaredOnlyOnWindows(label overriddenLabel: Int) {}
    }
#endif

public class FixtureClass312Taken {
    // Unrelated to the parameter of the same name, which is called only in a branch this build compiled.
    func handler() {}

    public func run(handler: () -> Void) {
        #if os(Linux) || os(macOS)
            handler()
        #endif
    }
}

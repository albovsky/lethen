public class FixtureStorage9 {
    // Read as a bare name in a skipped clause of its own type.
    var logger9 = 0
    // Read through `self.` nowhere and named by no skipped clause.
    var unread9 = 0
    // A local of the same name is what the skipped clause reads.
    var shadowed9 = 0
    // Control: called in a skipped clause, which already names any method of its name.
    func formatter9() -> Int { 0 }
    // Used-but-not-compared control: read in the clause this build compiled.
    var readNormally9 = 0
    // Named bare, with its labels, in a skipped clause.
    func show9(title _: String) {}
    // Control: the skipped clause's labels name the other overload.
    func show9(message _: String) {}
    // A local function of the same name is what the skipped clause reads.
    func localized9() -> Int { 0 }
    // A local type of the same name is what the skipped clause reads.
    var localType9 = 0
    // A closure's capture of the same name is what the skipped clause reads.
    var captured9 = 0
    // A bare `catch`'s implicit `error` is what the skipped clause reads.
    var error = 0
    // A setter's parameter of the same name is what the skipped clause reads.
    var setterParameter9 = 0
    // The implicit parameters of a setter and an observer are what the skipped clauses read.
    var newValue = 0
    var oldValue = 0
    private var stored9 = 0

    public var computed9: Int {
        get { stored9 }
        set(setterParameter9) {
            #if os(Windows)
                stored9 = setterParameter9
            #else
                stored9 = setterParameter9 + 1
            #endif
        }
    }

    public var implicitlyComputed9: Int {
        get { stored9 }
        set {
            #if os(Windows)
                stored9 = newValue
            #else
                stored9 = newValue + 1
            #endif
        }
    }

    public var observed9 = 0 {
        didSet {
            #if os(Windows)
                stored9 = oldValue
            #else
                stored9 = oldValue + 1
            #endif
        }
    }

    public init() {}

    public func value() -> Int {
        #if os(Windows)
            _ = show9(title:)
            return logger9 + formatter9()
        #else
            return readNormally9
        #endif
    }

    public func useLocalType() -> Any {
        struct localType9 {}
        #if os(Windows)
            return localType9.self
        #else
            // An indexed reference, so the index shows this clause compiled; a local type is not indexed.
            _ = readNormally9
            return localType9()
        #endif
    }

    public func callLocal() -> Int {
        func localized9() -> Int { 1 }
        #if os(Windows)
            let function = localized9
            return function()
        #else
            return localized9() + 1
        #endif
    }

    func fixtureThrowing9() throws {}

    public func caught() {
        do {
            try fixtureThrowing9()
        } catch {
            #if os(Windows)
                _ = error
            #else
                print(error)
            #endif
        }
    }

    public func capture() -> () -> Int {
        { [captured9 = 1] in
            #if os(Windows)
                return captured9
            #else
                return captured9 + 1
            #endif
        }
    }

    public func shadow() -> Int {
        let shadowed9 = 1
        #if os(Windows)
            return shadowed9
        #else
            return shadowed9 + 1
        #endif
    }
}

public class FixtureConditional9 {
    // Read bare in a skipped type-level clause whose other method has a parameter of the same name.
    var conditionalRead9 = 0

    public init() {}

    #if os(Windows)
        func run() -> Int { conditionalRead9 }
        func other(conditionalRead9: Int) -> Int { conditionalRead9 }
    #endif
}

public class FixtureOther9 {
    // Same name as a member of `FixtureStorage9`: the skipped clause there cannot read this one.
    var logger9 = 0

    public init() {}
}

public class FixtureBase9 {
    // Read as a bare name in a skipped clause of a subclass, which inherits it.
    var inherited9 = 0
}

public final class FixtureSub9: FixtureBase9 {
    public func run() -> Int {
        #if os(Windows)
            return inherited9
        #else
            return 0
        #endif
    }
}

extension Int {
    // Added to an unscanned type and read bare in a skipped clause of the same extension.
    var fixtureDoubled9: Int { self * 2 }

    public func fixtureUse9() -> Int {
        #if os(Windows)
            return fixtureDoubled9
        #else
            return self
        #endif
    }
}

// A function referenced as a value, rather than called, has its signature fixed by the function type it converts to,
// so its unused parameters cannot be removed.
class FixtureClass237 {
    // Retained: assigned to a function-typed property.
    func assignedFunc(unused: Int) {}

    // Retained: passed as an argument.
    func passedFunc(_ unused: Int) {}

    // Retained: a static method referenced as a value.
    static func staticValueFunc(unused: Int) {}

    // Retained: the base method is passed as a value, which fixes this override's signature too.
    func overriddenFunc(_ unused: Int) {}

    // Used-but-not-compared control: passed as a value and read, so used rather than retained.
    func passedFuncReadingParam(_ used: Int) {
        print(used)
    }

    // Reported: only called.
    func calledFunc(unused: Int) {}

    // Reported: called inside a closure, which fixes the closure's signature, not this one.
    func closureWrappedFunc(unused: Int) {}

    // Reported: only called.
    init(unused: Int) {}

    // Reported: a subscript is accessed, and the index gives no call role to tell a value use apart.
    subscript(unused: Int) -> Int { 0 }

    var handler: ((Int) -> Void)?

    func apply(_ body: (Int) -> Void) {
        body(0)
    }

    func run() {
        handler = assignedFunc
        apply(passedFunc)
        apply(passedFuncReadingParam)
        apply(overriddenFunc)
        let staticValue: (Int) -> Void = FixtureClass237.staticValueFunc
        staticValue(0)
        calledFunc(unused: 0)
        apply { closureWrappedFunc(unused: $0) }
        _ = self[0]
    }
}

class FixtureClass237Subclass: FixtureClass237 {
    override func overriddenFunc(_ unused: Int) {}
}

protocol FixtureProtocol237 {
    func valueRequirement(_ unused: Int)
    func calledRequirement(unused: Int)
}

// Retained: the requirement is passed as a value through the protocol, which fixes every witness's signature.
// Reported: the other requirement is only called and no witness reads its parameter.
class FixtureClass237Witness: FixtureProtocol237 {
    func valueRequirement(_ unused: Int) {}
    func calledRequirement(unused: Int) {}
}

public func fixtureClass237Entry() {
    let instance: FixtureClass237 = FixtureClass237Subclass(unused: 0)
    instance.run()
    let witness: FixtureProtocol237 = FixtureClass237Witness()
    instance.apply(witness.valueRequirement)
    witness.calledRequirement(unused: 0)
}

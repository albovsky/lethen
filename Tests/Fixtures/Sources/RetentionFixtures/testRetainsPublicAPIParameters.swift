// Parameters of retained public API keep their signature: clients outside the scan call it.
public class FixtureClass234 {
    // Retained: public and unused.
    public func publicFunc(unused: Int) {}

    // Used-but-not-compared control: public and read, so used rather than retained.
    public func publicFuncReadingParam(used: Int) {
        print(used)
    }

    // Reported: internal and unused, though its only caller is public.
    func internalFunc(unused: Int) {}

    // Retained: the public override fixes the signature of the internal base.
    func overriddenFunc(unused: Int) {}

    public func callInternalAPI() -> Any {
        internalFunc(unused: 0)
        overriddenFunc(unused: 0)
        let requirement: FixtureProtocol234Internal = FixtureClass234InternalWitness()
        requirement.internalRequirement(unused: 0)
        return FixtureClass234Witness()
    }
}

public class FixtureClass234Subclass: FixtureClass234 {
    override public func overriddenFunc(unused: Int) {}
}

public protocol FixtureProtocol234 {
    func requirement(unused: Int)
}

// Retained: an internal witness of a public requirement keeps the requirement's signature.
class FixtureClass234Witness: FixtureProtocol234 {
    func requirement(unused: Int) {}
}

protocol FixtureProtocol234Internal {
    func internalRequirement(unused: Int)
}

// Reported: an internal witness of an internal requirement that no conformance reads.
class FixtureClass234InternalWitness: FixtureProtocol234Internal {
    func internalRequirement(unused: Int) {}
}

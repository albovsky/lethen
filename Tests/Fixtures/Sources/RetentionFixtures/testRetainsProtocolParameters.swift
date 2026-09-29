import Foundation

protocol FixtureProtocol104 {
    // param1 used in single conformance
    func func1(param1: String, param2: String)
    // Unused
    func func2(param: String)
    // Used only in extension
    func func3(param: String)
    // Unused in extension, but used in conformance.
    func func4(param: String)
    // Unused, same name but different type to validate accuracy.
    func func4(param: Int)
    // param used in multiple conformances
    static func func5(param: String)
    // Used only in override
    func func6(param: String)
    // Unused, conforming functions are explicitly ignored
    func func7(_ param: String)
}

extension FixtureProtocol104 {
    func func3(param: String) {
        print(param)
    }

    func func4(param: String) {}
    func func4(param: Int) {}
}

public class FixtureClass104Class1: FixtureProtocol104 {
    func func1(param1: String, param2: String) {}
    func func2(param: String) {}

    static func func5(param: String) {
        print(param)
    }

    func func6(param: String) {}
    func func7(_: String) {}
}

public class FixtureClass104Class2: FixtureProtocol104 {
    func func1(param1: String, param2: String) {
        print(param1)
    }

    func func2(param: String) {}

    func func4(param: String) {
        print(param)
    }

    func func4(param: Int) {}

    static func func5(param: String) {
        print(param)
    }

    func func6(param: String) {}
    func func7(_: String) {}
}

public class FixtureClass104Class3: FixtureClass104Class2 {
    override func func6(param: String) {
        print(param)
    }
}

// The protocol and its witnesses are internal, so their parameters follow the conformance rules rather than the rule
// for retained public API. Calling each requirement keeps every witness in use.
public func fixtureFunction104Use() {
    let conformance: FixtureProtocol104 = FixtureClass104Class1()
    conformance.func1(param1: "", param2: "")
    conformance.func2(param: "")
    conformance.func3(param: "")
    conformance.func4(param: "")
    conformance.func4(param: 0)
    type(of: conformance).func5(param: "")
    conformance.func6(param: "")
    conformance.func7("")
}

import Foundation

public class FixtureClass101Base {
    // No overrides, unused.
    func func1(param: String) {}

    // Overridden, used only in base.
    func func2(param: String) { print(param) }

    // Used in override.
    func func3(param: String) {}

    // Used in deeply nested override.
    func func4(param: String) {}

    // Same name with different types, used to validate accuracy.
    func func4(param: Int) {}

    // Overridden, unused.
    func func5(param: String) {}

    // Overridden, declared in subclass extension.
    func func6(param: String) {}

    // Overridden in multiple subclass branches.
    func func7(param1: String, param2: String) {}
}

public class FixtureClass101Subclass1: FixtureClass101Base {
    override func func2(param: String) {}

    override func func3(param: String) {
        print(param)
    }

    override func func4(param: Int) {}

    override func func7(param1: String, param2: String) {
        print(param1)
    }
}

public class FixtureClass101Subclass2: FixtureClass101Subclass1 {
    override func func4(param: String) {
        print(param)
    }

    override func func4(param: Int) {}

    override func func5(param: String) {}

    override func func7(param1: String, param2: String) {}
}

public class FixtureClass101Subclass3: FixtureClass101Base {
    override func func7(param1: String, param2: String) {}
}

public class FixtureClass101InheritForeignBase: NSObject {
    public override func isEqual(_ object: Any?) -> Bool {
        return true
    }
}

public class FixtureClass101InheritForeignSubclass1: FixtureClass101InheritForeignBase {
    public override func isEqual(_ object: Any?) -> Bool {
        return true
    }
}

// The methods above are internal, so their parameters follow the override rules rather than the rule for retained
// public API. Calling each base method keeps the whole override chain in use.
public func fixtureFunction101Use() {
    let base = FixtureClass101Base()
    base.func1(param: "")
    base.func2(param: "")
    base.func3(param: "")
    base.func4(param: "")
    base.func4(param: 0)
    base.func5(param: "")
    base.func6(param: "")
    base.func7(param1: "", param2: "")
}

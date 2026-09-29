import CrossModuleRetentionSupportFixtures

class FixtureClass129: CrossModuleRetentionSupportFixtures.FixtureClass129 {}

// Explicitly retain CrossModuleRetentionFixtures.FixtureClass129 as we can't use
// --retain-public because it'll also retain CrossModuleRetentionSupportFixtures.FixtureClass129.
// periphery:ignore
class FixtureClass129Retainer {
    func retain() {
        _ = FixtureClass129.self
    }
}

// Control: public in a module that is not listed, so it is reported.
public class FixtureClass228Reported {}

// A witness in a target that is not listed of a requirement in a listed target: its unused parameter is retained.
class FixtureClass236Witness: FixtureProtocol236 {
    func handle(value: Int, context: String) {
        print(value)
    }
}

// Control: public in a module that is not listed, so its unused parameter is reported.
public func fixtureFunction236Reported(unused: Int) {}

// periphery:ignore
class FixtureClass236Retainer {
    func retain() {
        _ = FixtureClass236Witness()
        fixtureFunction236Reported(unused: 0)
    }
}

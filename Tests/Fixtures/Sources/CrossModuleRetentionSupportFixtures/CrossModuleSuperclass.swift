open class FixtureClass129 {}

// Retained by --retain-public-targets CrossModuleRetentionSupportFixtures; its consumers live outside the scan.
public class FixtureClass228 {}

// Its requirement is retained by --retain-public-targets CrossModuleRetentionSupportFixtures, so witnesses in other
// targets keep its signature.
public protocol FixtureProtocol236 {
    func handle(value: Int, context: String)
}

// Retained by --retain-public-targets CrossModuleRetentionSupportFixtures, with its unused parameter.
public func fixtureFunction236(unused: Int) {}

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

// Extended with initializers by CrossModuleRetentionFixtures.
public struct FixtureWidget11 {
    public init() {}
}

// An imported public type with an SDK alias's name shadows the alias at the use.
public struct CShort {
    public init(fixtureImported13 _: Int) {}
}

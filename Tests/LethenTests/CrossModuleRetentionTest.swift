import Configuration
import SystemPackage
@testable import TestShared

final class CrossModuleRetentionTest: SPMSourceGraphTestCase {
    override static func setUp() {
        super.setUp()

        setupState.capture {
            try build(projectPath: FixturesProjectPath)
            try index(configuration: Configuration())
        }
    }

    func testCrossModuleInheritanceWithSameName() {
        module("CrossModuleRetentionFixtures") {
            self.assertReferenced(.class("FixtureClass129"))
        }

        module("CrossModuleRetentionSupportFixtures") {
            self.assertReferenced(.class("FixtureClass129"))
        }
    }

    /// A construction qualified by the module that declares the type names an initializer another module adds to it.
    func testConfidenceSkippedBranchQualifiedByTheTypesModule() {
        // The extension's members are folded into the type it extends.
        module("CrossModuleRetentionSupportFixtures") {
            self.assertReferenced(.struct("FixtureWidget11")) {
                self.assertNotReferenced(.functionConstructor("init(fixtureTypesModule11:)"))
                self.assertConfidence(.functionConstructor("init(fixtureTypesModule11:)"), .likely)
                // Through a type alias another module declares.
                self.assertNotReferenced(.functionConstructor("init(fixtureAliasModule11:)"))
                self.assertConfidence(.functionConstructor("init(fixtureAliasModule11:)"), .likely)
                // Control: a module that declares no such type.
                self.assertNotReferenced(.functionConstructor("init(fixtureOtherModule11:)"))
                self.assertConfidence(.functionConstructor("init(fixtureOtherModule11:)"), .certain)
            }
        }
    }
}

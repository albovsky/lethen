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
}

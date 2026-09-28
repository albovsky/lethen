import Configuration
@testable import TestShared
import XCTest

final class RetainPublicTargetsTest: SPMSourceGraphTestCase {
    override static func setUp() {
        super.setUp()

        setupState.capture {
            try build(projectPath: FixturesProjectPath)
            let configuration = Configuration()
            configuration.retainPublicTargets = ["CrossModuleRetentionSupportFixtures"]
            try index(configuration: configuration)
        }
    }

    func testRetainsPublicDeclarationsOfListedTargetsOnly() {
        module("CrossModuleRetentionSupportFixtures") {
            self.assertReferenced(.class("FixtureClass228"))
            self.assertNotRedundantPublicAccessibility(.class("FixtureClass228"))
        }

        module("CrossModuleRetentionFixtures") {
            self.assertNotReferenced(.class("FixtureClass228Reported"))
        }
    }
}

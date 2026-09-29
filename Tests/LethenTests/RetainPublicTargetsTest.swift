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

    func testRetainsParametersOfPublicAPIOfListedTargetsOnly() {
        module("CrossModuleRetentionSupportFixtures") {
            self.assertReferenced(.functionFree("fixtureFunction236(unused:)")) {
                self.assertReferenced(.varParameter("unused"))
            }
            self.assertReferenced(.protocol("FixtureProtocol236")) {
                self.assertReferenced(.functionMethodInstance("handle(value:context:)")) {
                    self.assertReferenced(.varParameter("context"))
                }
            }
        }

        module("CrossModuleRetentionFixtures") {
            self.assertReferenced(.class("FixtureClass236Witness")) {
                self.assertReferenced(.functionMethodInstance("handle(value:context:)")) {
                    self.assertUsedParameter("value")
                    self.assertReferenced(.varParameter("context"))
                }
            }
            self.assertReferenced(.functionFree("fixtureFunction236Reported(unused:)")) {
                self.assertNotReferenced(.varParameter("unused"))
            }
        }
    }
}

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

    func testSDKAliasIsNotShadowedByAnUnimportedModule() {
        module("CrossModuleRetentionFixtures") {
            self.assertReferenced(.extensionStruct("Double")) {
                self.assertNotReferenced(.functionConstructor("init(fixturePlatform13:)"))
                self.assertConfidence(.functionConstructor("init(fixturePlatform13:)"), .likely)
                self.assertReferenced(.functionConstructor("init(fixturePlatformLive13:)"))
            }
            self.assertReferenced(.extensionStruct("Int16")) {
                self.assertNotReferenced(.functionConstructor("init(fixtureImported13:)"))
                self.assertConfidence(.functionConstructor("init(fixtureImported13:)"), .certain)
                self.assertReferenced(.functionConstructor("init(fixtureInt16Live13:)"))
            }
            self.assertReferenced(.extensionStruct("Float")) {
                self.assertNotReferenced(.functionConstructor("init(fixtureSDK13:)"))
                self.assertConfidence(.functionConstructor("init(fixtureSDK13:)"), .likely)
                self.assertNotReferenced(.functionConstructor("init(fixtureOther13:)"))
                self.assertConfidence(.functionConstructor("init(fixtureOther13:)"), .certain)
                self.assertReferenced(.functionConstructor("init(fixtureLive13:)"))
            }
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
                // Through a module that re-exports the type's module.
                self.assertNotReferenced(.functionConstructor("init(fixtureReexported11:)"))
                self.assertConfidence(.functionConstructor("init(fixtureReexported11:)"), .likely)
                // Control: a module that declares no such type.
                self.assertNotReferenced(.functionConstructor("init(fixtureOtherModule11:)"))
                self.assertConfidence(.functionConstructor("init(fixtureOtherModule11:)"), .certain)
            }
        }
    }
}

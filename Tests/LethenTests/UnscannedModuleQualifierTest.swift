import Configuration
import SystemPackage
@testable import TestShared

final class UnscannedModuleQualifierTest: SPMSourceGraphTestCase {
    override static func setUp() {
        super.setUp()
        setupState.capture {
            try build(projectPath: FixturesProjectPath)
            let sources = FixturesProjectPath.appending("Sources")
            try index(sourceFiles: [
                sources.appending("CrossModuleRetentionSupportFixtures/CrossModuleSuperclass.swift"),
                sources.appending("CrossModuleRetentionFixtures/testUnscannedModuleQualifier.swift"),
            ], configuration: .init())
        }
    }

    func testImportedModuleNameCanBeAnExternalType() {
        assertReferenced(.struct("FixtureWidget11")) {
            self.assertNotReferenced(.functionConstructor("init(fixtureNested13:)"))
            self.assertConfidence(.functionConstructor("init(fixtureNested13:)"), .likely)
            self.assertConfidence(.functionConstructor("init(fixtureUnused13:)"), .certain)
            self.assertReferenced(.functionConstructor("init(fixtureLive13:)"))
        }
    }
}

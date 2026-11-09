import Configuration
@testable import PeripheryKit
@testable import TestShared
import XCTest

final class SPMProjectTest: SPMSourceGraphTestCase {
    override static func setUp() {
        super.setUp()

        setupState.capture {
            try build(projectPath: SPMProjectPath)
            try index(configuration: Configuration())
        }
    }

    func testMainEntryFile() {
        assertReferenced(.functionFree("main()"))
    }

    func testTopLevelCodeAfterUnusedGlobal() {
        assertReferenced(.functionFree("main()"))
        assertReferenced(.class("PublicCrossModuleReferenced"))
        assertNotReferenced(.varGlobal("unusedGlobalBeforeTopLevelCode"))
    }

    func testCrossModuleReference() {
        assertReferenced(.class("PublicCrossModuleReferenced"))
        assertNotReferenced(.class("PublicCrossModuleNotReferenced"))
    }

    func testMacroPeerRecallCanary() {
        // Only the peer generated for MockedProtocol is named by the test target.
        // The diagnostic belongs to the editable protocol. The compiler-generated peer is implicit.
        XCTAssertFalse(Self.results.contains { $0.declaration.name == "UnusedMockedProtocolMock" })
        assertNotReferenced(.protocol("UnusedMockedProtocol"))
        assertReferenced(.class("PublicCrossModuleReferenced")) // Ordinary class referenced across modules.
        assertReferenced(.class("MockedProtocolMock"))
        assertReferenced(.protocol("MockedProtocol"))
    }

    func testMacroImport() {
        assertReferenced(.module("SPMProjectKit"))
    }
}

import Configuration
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

    func testCrossModuleReference() {
        assertReferenced(.class("PublicCrossModuleReferenced"))
        assertNotReferenced(.class("PublicCrossModuleNotReferenced"))
    }

    func testMacroImport() {
        assertReferenced(.module("SPMProjectKit"))
    }
}

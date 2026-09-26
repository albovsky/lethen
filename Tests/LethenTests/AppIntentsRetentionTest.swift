#if os(macOS)
    @testable import TestShared
    import XCTest

    final class AppIntentsRetentionTest: FixtureSourceGraphTestCase {
        func testRetainsAppIntent() throws {
            try analyze {
                assertReferenced(.struct("SimpleIntent"))
            }
        }

        func testRetainsAppEntity() throws {
            try analyze {
                assertReferenced(.struct("SimpleEntity"))
                assertReferenced(.struct("SimpleEntityQuery"))
            }
        }

        func testRetainsAppEnum() throws {
            try analyze {
                assertReferenced(.enum("SimpleAppEnum"))
            }
        }

        func testRetainsAppShortcutsProvider() throws {
            try analyze {
                assertReferenced(.struct("SimpleShortcutsProvider"))
            }
        }
    }
#endif

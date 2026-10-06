#if os(macOS)
    @testable import TestShared
    import XCTest

    final class AppIntentsRetentionTest: FixtureSourceGraphTestCase {
        func testRetainsAppIntent() throws {
            try analyze {
                assertReferenced(.struct("SimpleIntent"))
            }
        }

        func testRetainsAppIntentStaticWitnesses() throws {
            try analyze {
                assertReferenced(.struct("StaticWitnessIntent")) {
                    assertReferenced(.varStatic("title"))
                    assertReferenced(.varStatic("description"))
                    // Used-but-not-compared control: retained by its use, not by name.
                    assertReferenced(.varStatic("preview"))
                    assertNotReferenced(.varStatic("unusedHelper"))
                }
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

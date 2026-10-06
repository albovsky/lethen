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
                    self.assertReferenced(.varStatic("title"))
                    self.assertReferenced(.varStatic("description"))
                    // Used-but-not-compared control: retained by its use, not by name.
                    self.assertReferenced(.varStatic("preview"))
                    self.assertNotReferenced(.varStatic("unusedHelper"))
                    self.assertNotReferenced(.varStatic("defaultQuery"))
                }
            }
        }

        func testRetainsAppEntityRefinementStaticWitnesses() throws {
            try analyze {
                assertReferenced(.struct("RefinedEntity")) {
                    self.assertReferenced(.varStatic("typeDisplayRepresentation"))
                    self.assertNotReferenced(.varStatic("unusedEntityHelper"))
                    // Collision control: a name only an intent declares is not retained on an entity.
                    self.assertNotReferenced(.varStatic("title"))
                }
            }
        }

        func testRetainsSupportedModesStaticWitness() throws {
            try analyze {
                assertReferenced(.struct("ModesIntent")) {
                    self.assertReferenced(.varStatic("title"))
                    self.assertReferenced(.varStatic("supportedModes"))
                    self.assertNotReferenced(.varStatic("unusedModesHelper"))
                }
            }
        }

        func testRetainsUnionValueStaticWitnesses() throws {
            try analyze {
                assertReferenced(.enum("UnionChoice")) {
                    self.assertReferenced(.varStatic("caseDisplayRepresentations"))
                    self.assertNotReferenced(.varStatic("unusedUnionHelper"))
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

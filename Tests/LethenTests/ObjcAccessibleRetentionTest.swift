import SystemPackage
@testable import TestShared
import XCTest

#if os(macOS)
    final class ObjcAccessibleRetentionTest: FixtureSourceGraphTestCase {
        func testRetainsOptionalProtocolMethodImplementedInSubclass() throws {
            try analyze(retainPublic: true) {
                assertReferenced(.class("FixtureClass125Base"))
                assertReferenced(.class("FixtureClass125")) {
                    self.assertReferenced(.functionMethodInstance("fileManager(_:shouldRemoveItemAtPath:)"))
                }
            }
        }

        func testRetainsOptionalProtocolMethod() throws {
            try analyze(retainPublic: true) {
                assertReferenced(.class("FixtureClass127")) {
                    self.assertReferenced(.functionMethodInstance("someFunc()"))
                }
                assertReferenced(.protocol("FixtureProtocol127")) {
                    self.assertReferenced(.functionMethodInstance("optionalFunc()"))
                }
            }
        }

        func testRetainsObjcAnnotatedClass() throws {
            try analyze(retainObjcAccessible: true) {
                assertReferenced(.class("FixtureClass21"))
            }
        }

        func testRetainsImplicitlyObjcAccessibleClass() throws {
            try analyze(retainObjcAccessible: true) {
                assertReferenced(.class("FixtureClass126"))
            }
        }

        func testRetainsObjcAnnotatedMembers() throws {
            try analyze(retainObjcAccessible: true) {
                assertReferenced(.class("FixtureClass22")) {
                    self.assertReferenced(.varInstance("someVar"))
                    self.assertReferenced(.functionMethodInstance("someMethod()"))
                    self.assertReferenced(.functionMethodInstance("somePrivateMethod()"))
                }
            }
        }

        func testDoesNotRetainObjcAnnotatedWithoutOption() throws {
            try analyze {
                assertNotReferenced(.class("FixtureClass23"))
            }
        }

        func testDoesNotRetainMembersOfObjcAnnotatedClass() throws {
            try analyze(retainObjcAccessible: true) {
                assertReferenced(.class("FixtureClass24")) {
                    self.assertNotReferenced(.functionMethodInstance("someMethod()"))
                    self.assertNotReferenced(.varInstance("someVar"))
                }
            }
        }

        func testObjcMembersAnnotationRetainsMembers() throws {
            try analyze(retainObjcAccessible: true) {
                assertReferenced(.class("FixtureClass25")) {
                    self.assertReferenced(.varInstance("someVar"))
                    self.assertReferenced(.functionMethodInstance("someMethod()"))
                    self.assertNotReferenced(.functionMethodInstance("somePrivateMethod()"))
                }
            }
        }

        func testConfidenceLikelyForObjcAccessible() throws {
            try analyze(retainPublic: true) {
                assertReferenced(.class("FixtureClass232")) {
                    self.assertNotReferenced(.functionMethodInstance("exposed()"))
                    self.assertConfidence(.functionMethodInstance("exposed()"), .likely)
                    self.assertConfidence(.functionMethodInstance("plain()"), .certain)
                }
            }

            // With the retention flag the declaration is retained, so no result carries a confidence.
            try analyze(retainPublic: true, retainObjcAccessible: true) {
                assertReferenced(.class("FixtureClass232")) {
                    self.assertReferenced(.functionMethodInstance("exposed()"))
                }
            }
        }
    }
#endif

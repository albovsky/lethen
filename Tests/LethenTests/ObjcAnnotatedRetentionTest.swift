import SystemPackage
@testable import TestShared
import XCTest

#if os(macOS)
    final class ObjcAnnotatedRetentionTest: FixtureSourceGraphTestCase {
        func testRetainsAnnotatedExtensionDeclarations() throws {
            try analyze(retainObjcAnnotated: true) {
                assertReferenced(.class("FixtureClass214")) {
                    self.assertReferenced(.functionMethodInstance("methodInExtension()"))
                }
            }
        }

        func testRetainsExtensionDeclarationsOnObjcMembersAnnotatedClass() throws {
            try analyze(retainObjcAnnotated: true) {
                assertReferenced(.class("FixtureClass217")) {
                    self.assertReferenced(.functionMethodInstance("methodInExtension()"))
                }
            }
        }

        func testRetainsObjcProtocolMembers() throws {
            try analyze(retainObjcAnnotated: true) {
                assertReferenced(.protocol("FixtureProtocol215")) {
                    self.assertReferenced(.functionMethodInstance("methodInProtocol()"))
                }
            }
        }

        func testRetainsObjcProtocolConformingDeclarations() throws {
            try analyze(retainObjcAnnotated: true) {
                assertReferenced(.protocol("FixtureProtocol216"))
                assertReferenced(.class("FixtureClass216")) {
                    self.assertReferenced(.functionMethodInstance("methodInProtocol()"))
                }
            }
        }
    }
#endif

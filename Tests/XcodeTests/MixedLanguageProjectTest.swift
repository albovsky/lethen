import Configuration
@testable import TestShared
import XCTest

/// Swift declarations used only from Objective-C. MixedLanguageProject's `ObjCCaller.m` imports the
/// generated `MixedLanguageProject-Swift.h` and calls into `ObjCExposed.swift`; `ObjCCaller.h` names one
/// Swift class in a function prototype.
final class MixedLanguageProjectTest: XcodeSourceGraphTestCase {
    override static func setUp() {
        super.setUp()

        let configuration = Configuration()
        configuration.schemes = ["MixedLanguageProject"]

        setupState.capture {
            try build(projectPath: MixedLanguageProjectPath, configuration: configuration)
            try index(configuration: configuration)
        }
    }

    func testRetainsMembersUsedFromObjectiveC() {
        assertReferenced(.class("CalledFromObjC")) {
            self.assertReferenced(.functionMethodInstance("calledFromObjC()"))
            self.assertReferenced(.functionMethodInstance("renamedInSwift()"))
            self.assertReferenced(.varInstance("readFromObjC"))
            self.assertReferenced(.varStatic("staticReadFromObjC"))
            // Read with message syntax, which names only the getter.
            self.assertReferenced(.varInstance("readByMessage"))
            self.assertReferenced(.varStatic("staticReadByMessage"))
            self.assertReferenced(.functionMethodInstance("calledInExtension()"))
            // Exposed to Objective-C but never called from it.
            self.assertNotReferenced(.functionMethodInstance("notCalledFromObjC(_:)"))
            self.assertNotReferenced(.functionMethodInstance("notExposed()"))
        }
    }

    func testRetainsExtensionMemberOfFrameworkClassCalledFromObjectiveC() {
        assertReferenced(.extensionClass("NSObject")) {
            self.assertReferenced(.functionMethodInstance("calledOnFrameworkClass()"))
            self.assertNotReferenced(.functionMethodInstance("notCalledOnFrameworkClass()"))
        }
    }

    func testRetainsTypesUsedFromObjectiveC() {
        assertReferenced(.class("AllocatedFromObjC"))
        assertReferenced(.class("RenamedClass"))
        assertReferenced(.protocol("ProtocolAdoptedInObjC"))
        assertReferenced(.enum("EnumUsedFromObjC")) {
            self.assertReferenced(.enumelement("usedCase"))
        }
    }

    /// Xcode's clang units name no module, so a use from Objective-C counts as a use from another
    /// module and a public declaration used from Objective-C is not redundantly public; one used only
    /// from Swift in its own module is.
    func testPublicDeclarationUsedFromObjectiveCIsNotRedundantlyPublic() {
        assertReferenced(.class("PublicAllocatedFromObjC"))
        assertNotRedundantPublicAccessibility(.class("PublicAllocatedFromObjC"))
        assertRedundantPublicAccessibility(.class("PublicUsedFromSwift"))
    }

    /// The reference is in the header's own record, not the `.m` file that includes it.
    func testRetainsClassNamedOnlyInObjectiveCHeader() {
        assertReferenced(.class("NamedInObjCHeader"))
    }

    /// Clang does not index the generated header's declarations of Swift symbols, only its `@class`
    /// forward declarations, so a class named only in the signature of an unused `@objc` method stays
    /// unused.
    func testGeneratedHeaderIsNotAReference() {
        assertNotReferenced(.class("OnlyInExposedSignature"))
        assertNotReferenced(.class("NotReferencedFromObjC"))
    }

    /// `@class Name;` declares the class without using it.
    func testForwardDeclarationIsNotAReference() {
        assertNotReferenced(.class("OnlyForwardDeclared"))
    }

    /// Confidence is unchanged in this slice: an exposed declaration with no reference stays likely.
    func testUnreferencedExposedDeclarationStaysLikely() {
        assertConfidence(.class("NotReferencedFromObjC"), .likely)
        assertReferenced(.class("CalledFromObjC")) {
            self.assertConfidence(.functionMethodInstance("notExposed()"), .certain)
        }
    }

    func testExplainNamesTheObjectiveCLocation() throws {
        let output = try XCTUnwrap(explanation(of: .class("AllocatedFromObjC")))

        XCTAssertTrue(output.contains("Used, through this chain of references:"), output)
        XCTAssertTrue(output.contains("Objective-C code at "), output)
        XCTAssertTrue(output.contains("ObjCCaller.m:22:13 references class AllocatedFromObjC"), output)

        let header = try XCTUnwrap(explanation(of: .class("NamedInObjCHeader")))
        XCTAssertTrue(header.contains("ObjCCaller.h:6:28 references class NamedInObjCHeader"), header)
    }
}

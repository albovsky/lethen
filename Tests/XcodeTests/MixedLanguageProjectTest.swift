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

    /// Every Objective-C file of the scheme has an index unit, so an exposed declaration that no
    /// Objective-C code references is certainly unused, as is one not exposed at all.
    func testUnreferencedExposedDeclarationIsCertainWhenEveryObjectiveCFileWasIndexed() {
        assertConfidence(.class("NotReferencedFromObjC"), .certain)
        assertReferenced(.class("CalledFromObjC")) {
            self.assertConfidence(.functionMethodInstance("notCalledFromObjC(_:)"), .certain)
            self.assertConfidence(.functionMethodInstance("notExposed()"), .certain)
        }
    }

    /// The control: a used declaration has no result, so it has no confidence to be wrong about.
    func testDeclarationUsedFromObjectiveCIsReferencedNotCompared() {
        assertReferenced(.class("CalledFromObjC")) {
            self.assertReferenced(.functionMethodInstance("calledFromObjC()"))
            self.assertReferenced(.varInstance("readFromObjC"))
        }
    }

    /// Names that Objective-C code spells in a selector, a class-name string, or a key-value coding key
    /// are lookups by name, which the index cannot show as references, so they stay likely.
    func testNamesSpelledInObjectiveCLiteralsAreLikely() {
        assertReferenced(.class("CalledFromObjC")) {
            self.assertNotReferenced(.functionMethodInstance("namedInSelector()"))
            self.assertConfidence(.functionMethodInstance("namedInSelector()"), .likely)
            self.assertNotReferenced(.varInstance("kvcRead"))
            self.assertConfidence(.varInstance("kvcRead"), .likely)
        }
        assertNotReferenced(.class("NamedInObjCString"))
        assertConfidence(.class("NamedInObjCString"), .likely)
    }

    func testPlanRecordsCompleteClangCoverage() throws {
        let coverage = try XCTUnwrap(Self.plan?.clangCoverage)
        XCTAssertEqual(coverage.unindexedFiles, [])
        XCTAssertFalse(try XCTUnwrap(Self.plan).clangSourceFiles.isEmpty)
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

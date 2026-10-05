@testable import PeripheryKit
import SystemPackage
@testable import TestShared
import XCTest

final class RetentionTest: FixtureSourceGraphTestCase {
    func testNonReferencedClass() throws {
        try analyze {
            assertNotReferenced(.class("FixtureClass1"))
        }
    }

    /// `lethen explain` reads the assessor the report was built from, so the two cannot disagree.
    func testResultsAndExplainShareOneConfidenceAssessment() throws {
        try analyze {
            assertNotReferenced(.class("FixtureConfidenceNamedInLiteral"))
            assertConfidence(.class("FixtureConfidenceNamedInLiteral"), .likely)
            assertNotReferenced(.class("FixtureConfidenceNamedInBareLiteral"))
            assertConfidence(.class("FixtureConfidenceNamedInBareLiteral"), .certain)
            assertNotReferenced(.class("FixtureConfidenceNamedNowhere"))
            assertConfidence(.class("FixtureConfidenceNamedNowhere"), .certain)
            XCTAssertFalse(Self.results.isEmpty)
            for result in Self.results {
                XCTAssertEqual(Self.confidence.assess(result.declaration).confidence, result.confidence, "\(result.declaration)")
                XCTAssertEqual(Self.confidence.assess(result.declaration).reason, result.confidenceReason, "\(result.declaration)")
            }
        }
    }

    func testNonReferencedFreeFunction() throws {
        try analyze {
            assertNotReferenced(.functionFree("someFunction()"))
        }
    }

    func testNonReferencedMethod() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass2")) {
                self.assertNotReferenced(.functionMethodInstance("someMethod()"))
            }
        }
    }

    func testNonReferencedProperty() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass3")) {
                self.assertNotReferenced(.varStatic("someStaticVar"))
                self.assertNotReferenced(.varInstance("someVar"))
            }
        }
    }

    func testNonReferencedMethodInClassExtension() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass4")) {
                self.assertNotReferenced(.functionMethodInstance("someMethod()"))
            }
        }
    }

    func testConformingProtocolReferencedByNonReferencedClass() throws {
        try analyze {
            assertNotReferenced(.class("FixtureClass6"))
            assertNotReferenced(.protocol("FixtureProtocol1"))
        }
    }

    func testSelfReferencedClass() throws {
        try analyze {
            assertNotReferenced(.class("FixtureClass8"))
        }
    }

    func testSelfReferencedRecursiveMethod() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass9")) {
                self.assertNotReferenced(.functionMethodInstance("recursive()"))
            }
        }
    }

    func testRetainsSelfReferencedMethodViaReceiver() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass92")) {
                self.assertReferenced(.functionMethodInstance("someFunc()"))
            }
        }
    }

    func testRetainsReferencedMethodViaReceiver() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass113")) {
                self.assertReferenced(.functionMethodStatic("make()"))
            }
        }
    }

    func testSelfReferencedProperty() throws {
        try analyze {
            assertNotReferenced(.class("FixtureClass39"))
        }
    }

    func testRetainsInheritedClass() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass13")) {
                self.assertReferenced(.varInstance("cls"))
            }

            assertReferenced(.class("FixtureClass11"))
            assertReferenced(.class("FixtureClass12"))
        }
    }

    func testCrossReferencedClasses() throws {
        try analyze {
            assertNotReferenced(.class("FixtureClass14"))
            assertNotReferenced(.class("FixtureClass15"))
            assertNotReferenced(.class("FixtureClass16"))
        }
    }

    func testDeeplyNestedClassReferences() throws {
        try analyze {
            assertNotReferenced(.class("FixtureClass17"))
        }
    }

    func testRetainPublicMembers() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass26")) {
                self.assertReferenced(.functionMethodInstance("funcPublic()"))
                self.assertNotReferenced(.functionMethodInstance("funcPrivate()"))
                self.assertNotReferenced(.functionMethodInstance("funcInternal()"))
                self.assertReferenced(.functionMethodInstance("funcOpen()"))
            }
        }
    }

    func testConformanceToExternalProtocolIsRetained() throws {
        try analyze(retainPublic: true) {
            // Retained because it's a method from an external declaration (in this case, Equatable)
            assertReferenced(.class("FixtureClass55")) {
                self.assertReferenced(.functionOperatorInfix("==(_:_:)"))
            }
        }
    }

    func testSimpleRedundantProtocol() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass114"))
            assertReferenced(.protocol("FixtureProtocol114"))
            assertRedundantProtocol("FixtureProtocol114",
                                    implementedBy:
                                    .class("FixtureClass114"),
                                    .class("FixtureClass115"),
                                    .struct("FixtureStruct116"))
        }
    }

    func testRedundantProtocolThatInheritsAnyObject() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass121"))
            assertReferenced(.protocol("FixtureProtocol121"))
            assertRedundantProtocol("FixtureProtocol121", implementedBy: .class("FixtureClass121"))

            assertReferenced(.class("FixtureClass122"))
            assertReferenced(.protocol("FixtureProtocol122"))
            assertRedundantProtocol("FixtureProtocol122", implementedBy: .class("FixtureClass122"))
        }
    }

    func testRedundantProtocolThatInheritsForeignProtocol() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass118"))
            assertReferenced(.protocol("FixtureProtocol118"))
            // Protocols that inherit external protocols cannot be guaranteed to be redundant.
            assertNotRedundantProtocol("FixtureProtocol118")
        }
    }

    func testRedundantProtocolThatInheritsOtherProtocols() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass134"))

            assertReferenced(.protocol("FixtureProtocol128"))
            assertRedundantProtocol(
                "FixtureProtocol128",
                implementedBy: .class("FixtureClass134"),
                inherits: .protocol("FixtureProtocol128_Inherited")
            )
        }
    }

    func testProtocolUsedAsExistentialType() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass119"))
            assertReferenced(.protocol("FixtureProtocol119")) {
                self.assertNotReferenced(.functionMethodInstance("protocolFunc()"))
            }
            // Protocol is not redundant even though none of its members are called as it's used an existential type.
            assertNotRedundantProtocol("FixtureProtocol119")
        }
    }

    func testProtocolVarReferencedByProtocolMethodInSameClassIsRedundant() throws {
        // Despite the conforming class depending internally upon the protocol methods, the protocol
        // itself is unused. In a real situation the protocol could be removed and the conforming
        // class refactored.
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass51")) {
                self.assertReferenced(.functionMethodInstance("publicMethod()"))
                self.assertReferenced(.functionMethodInstance("protocolMethod()"))
                self.assertReferenced(.varInstance("protocolVar"))
            }
            assertReferenced(.protocol("FixtureProtocol51"))
            assertRedundantProtocol("FixtureProtocol51", implementedBy: .class("FixtureClass51"))
        }
    }

    func testProtocolMethodCalledIndirectlyByProtocolIsRetained() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass52")) {
                self.assertReferenced(.functionMethodInstance("protocolMethod()"))
            }
            assertReferenced(.protocol("FixtureProtocol52"))
        }
    }

    func testDoesNotRetainProtocolMethodInSubclassWithDefaultImplementation() throws {
        // Protocol witness tables are only associated with the conforming class, and do not
        // descent to subclasses. Therefore, a protocol method that's only implemented in a subclass
        // and not the parent conforming class is actually unused.
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol83")) {
                self.assertReferenced(.functionMethodInstance("protocolMethod()"))
            }

            assertReferenced(.extensionProtocol("FixtureProtocol83")) {
                self.assertReferenced(.functionMethodInstance("protocolMethod()"))
            }

            assertReferenced(.class("FixtureClass84")) {
                self.assertNotReferenced(.functionMethodInstance("protocolMethod()"))
            }
        }
    }

    func testRetainsProtocolExtension() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.extensionProtocol("FixtureProtocol81"))
        }
    }

    func testUnusedProtocolWithExtension() throws {
        try analyze(retainPublic: true) {
            assertNotReferenced(.protocol("FixtureProtocol82"))
            assertNotReferenced(.extensionProtocol("FixtureProtocol82"))
        }
    }

    func testRetainsProtocolMethodImplementedInExtension() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass80")) {
                self.assertReferenced(.functionMethodInstance("someMethod()"))
                self.assertReferenced(.functionMethodInstance("protocolMethodWithUnusedDefault()"))
            }
            assertReferenced(.protocol("FixtureProtocol80")) {
                self.assertReferenced(.functionMethodInstance("protocolMethod()"))
                self.assertReferenced(.functionMethodInstance("protocolMethodWithUnusedDefault()"))
            }
            assertReferenced(.extensionProtocol("FixtureProtocol80")) {
                // The protocol extension contains a default implementation but it's unused because
                // the class also implements the function. Regardless, it needs to be retained.
                self.assertReferenced(.functionMethodInstance("protocolMethodWithUnusedDefault()"))
            }
        }
    }

    func testRetainsNonProtocolMethodDefinedInProtocolExtension() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass66")) {
                self.assertReferenced(.functionMethodInstance("someMethod()"))
            }
            assertReferenced(.protocol("FixtureProtocol66")) {
                // Even though the protocol is retained because of the use of method declared
                // within the extension, the protocol method itself is not used.
                self.assertNotReferenced(.functionMethodInstance("protocolMethod()"))
            }
            assertReferenced(.extensionProtocol("FixtureProtocol66")) {
                self.assertReferenced(.functionMethodInstance("nonProtocolMethod()"))
            }
        }
    }

    func testDoesNotRetainUnusedProtocolMethodWithDefaultImplementation() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol84")) {
                self.assertReferenced(.functionMethodInstance("usedMethod()"))
                self.assertNotReferenced(.functionMethodInstance("unusedMethod()"))
            }
            assertReferenced(.extensionProtocol("FixtureProtocol84")) {
                self.assertReferenced(.functionMethodInstance("usedMethod()"))
                self.assertNotReferenced(.functionMethodInstance("unusedMethod()"))
            }
        }
    }

    func testRetainedProtocolDoesNotRetainUnusedClass() throws {
        try analyze(retainPublic: true) {
            assertNotReferenced(.class("FixtureClass57"))
            assertReferenced(.protocol("FixtureProtocol57"))
        }
    }

    func testRetainedProtocolDoesNotRetainImplementationInUnusedClass() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol200")) {
                self.assertReferenced(.functionMethodInstance("protocolFunc()"))
            }
            assertNotReferenced(.class("FixtureClass200"))
            assertNotReferenced(.class("FixtureClass201"))
        }
    }

    func testRetainOverridingMethod() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass67")) {
                self.assertReferenced(.functionMethodInstance("someMethod()"))
            }
            assertReferenced(.class("FixtureClass68")) {
                self.assertReferenced(.functionMethodInstance("someMethod()"))
            }
        }
    }

    func testUnusedOverriddenMethod() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass81Base")) {
                self.assertNotReferenced(.functionMethodInstance("someMethod()"))
            }
            assertReferenced(.class("FixtureClass81Sub")) {
                self.assertReferenced(.functionMethodInstance("someMethod()"))
            }
        }
    }

    func testOverriddenMethodRetainedBySuper() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass82Base")) {
                self.assertReferenced(.functionMethodInstance("someMethod()"))
            }
            assertReferenced(.class("FixtureClass82Sub")) {
                self.assertReferenced(.functionMethodInstance("someMethod()"))
            }
        }
    }

    func testEnumCases() throws {
        let enumTypes = ["String", "Character", "Int", "Float", "Double", "RawRepresentable"]
        try analyze(retainPublic: true) {
            assertReferenced(.enum("Fixture28Enum_Bare")) {
                self.assertReferenced(.enumelement("used"))
                self.assertNotReferenced(.enumelement("unused"))
            }

            for enumType in enumTypes {
                let enumName = "Fixture28Enum_\(enumType)"

                assertReferenced(.enum(enumName)) {
                    self.assertReferenced(.enumelement("used"))
                    self.assertReferenced(.enumelement("unused"))
                }
            }
        }
    }

    func testRetainsPublicEnumCases() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.enum("FixtureEnum179")) {
                self.assertReferenced(.enumelement("someCase"))
            }
        }
    }

    func testRetainsDestructor() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass40")) {
                self.assertReferenced(.functionDestructor("deinit"))
            }
        }
    }

    func testRetainsDefaultConstructor() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass41")) {
                self.assertReferenced(.functionConstructor("init()"))
            }
        }
    }

    func testAccessibility() throws {
        try analyze {
            assertAccessibility(.class("FixtureClass31"), .public) {
                self.assertAccessibility(.functionConstructor("init(arg:)"), .public)
                self.assertAccessibility(.functionMethodInstance("openFunc()"), .open)

                self.assertAccessibility(.class("FixtureClass31Inner"), .public) {
                    self.assertAccessibility(.functionMethodInstance("privateFunc()"), .private)
                }
            }

            assertAccessibility(.class("FixtureClass32"), .private) {
                self.assertAccessibility(.varInstance("publicVar"), .public)
            }

            assertAccessibility(.class("FixtureClass33"), .internal)

            assertAccessibility(.enum("Enum1"), .internal) {
                self.assertAccessibility(.functionMethodInstance("publicEnumFunc()"), .public)
            }

            assertAccessibility(.class("FixtureClass50"), .public) {
                self.assertAccessibility(.functionMethodInstance("publicMethodInExtension()"), .public)
                self.assertAccessibility(.functionMethodInstance("methodInPublicExtension()"), .public)
                self.assertAccessibility(.functionMethodStatic("staticMethodInPublicExtension()"), .public)
                self.assertAccessibility(.varStatic("staticVarInExtension"), .public)
                self.assertAccessibility(.functionMethodInstance("privateMethodInPublicExtension()"), .private)
                self.assertAccessibility(.functionMethodInstance("internalMethodInPublicExtension()"), .internal)
            }

            assertAccessibility(.extensionStruct("Array"), .public) {
                self.assertAccessibility(.functionMethodInstance("methodInExternalStructTypeExtension()"), .public)
            }

            assertAccessibility(.extensionProtocol("Sequence"), .public) {
                self.assertAccessibility(.functionMethodInstance("methodInExternalProtocolTypeExtension()"), .public)
            }

            assertAccessibility(.extensionStruct("Name"), .public) {
                self.assertAccessibility(.varStatic("CustomNotification"), .public)
            }
        }
    }

    func testXCTestCaseClassesAndMethodsAreRetained() throws {
        try analyze {
            assertReferenced(.class("FixtureClass34")) {
                self.assertReferenced(.functionMethodInstance("testSomething()"))
                self.assertNotReferenced(.functionMethodInstance("testNotATest(param:)"))
                self.assertReferenced(.functionMethodInstance("setUp()"))
                self.assertReferenced(.functionMethodStatic("setUp()"))
            }
            assertReferenced(.class("FixtureClass34Subclass")) {
                self.assertReferenced(.functionMethodInstance("testSubclass()"))
            }
        }
    }

    func testExternalXCTestCaseClass() throws {
        try analyze(externalTestCaseClasses: ["ExternalTestCase"]) {
            assertReferenced(.class("FixtureClass217")) {
                self.assertReferenced(.functionMethodInstance("testSomeTestCase()"))
            }
        }
    }

    func testRetainsMethodDefinedInExtensionOnStandardType() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass35")) {
                self.assertReferenced(.functionMethodInstance("testSomething()"))
            }
            assertReferenced(.extensionStruct("String")) {
                self.assertReferenced(.varInstance("trimmed"))
            }
        }
    }

    func testRetainsGenericType() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass37"))
            assertReferenced(.protocol("FixtureProtocol37"))
        }
    }

    func testRetainsGenericProtocolExtensionMembers() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol38"))
            assertReferenced(.extensionProtocol("FixtureProtocol38")) {
                self.assertReferenced(.functionMethodInstance("someFunc()"))
            }

            assertReferenced(.protocol("FixtureProtocol39"))
            assertReferenced(.extensionProtocol("FixtureProtocol39")) {
                self.assertReferenced(.functionMethodInstance("someFunc()"))
            }

            assertReferenced(.protocol("FixtureProtocol40"))
            assertReferenced(.extensionProtocol("FixtureProtocol40")) {
                self.assertReferenced(.functionMethodInstance("someFunc()"))
            }
        }
    }

    func testUnusedTypealias() throws {
        try analyze {
            assertNotReferenced(.typealias("UnusedAlias"))
        }
    }

    func testRetainsConstructorOfGenericClassAndStruct() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass61")) {
                self.assertReferenced(.functionConstructor("init(someVar:)"))
            }
            assertReferenced(.struct("FixtureStruct61")) {
                self.assertReferenced(.functionConstructor("init(someVar:)"))
            }
        }
    }

    func testFunctionAccessorsRetainReferences() throws {
        try analyze(retainPublic: true, retainAssignOnlyProperties: true) {
            assertReferenced(.class("FixtureClass63")) {
                self.assertReferenced(.varInstance("referencedByGetter"))
                self.assertReferenced(.varInstance("referencedBySetter"))
                self.assertReferenced(.varInstance("referencedByDidSet"))
            }
        }
    }

    func testAssignOnlyPropertyAnalysisDoesNotApplyToProtocolProperties() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol124")) {
                self.assertReferenced(.varInstance("someProperty"))
            }
            assertReferenced(.class("FixtureClass124")) {
                self.assertReferenced(.varInstance("someProperty"))
            }
        }
    }

    func testPropertyReferencedByComputedValue() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass78")) {
                self.assertReferenced(.varInstance("someVar"))
                self.assertReferenced(.varInstance("someOtherVar"))
                self.assertNotReferenced(.varInstance("unusedVar"))
            }
        }
    }

    func testInstanceVarReferencedInClosure() throws {
        try analyze(retainPublic: true, retainAssignOnlyProperties: true) {
            assertReferenced(.class("FixtureClass69")) {
                self.assertReferenced(.varInstance("someVar"))
            }
        }
    }

    func testCodingKeyEnum() throws {
        try analyze(
            retainPublic: true,
            // CustomStringConvertible doesn't actually inherit Codable, we're just using it because we don't have an
            // external module in which to declare our own type.
            externalCodableProtocols: ["CustomStringConvertible"]
        ) {
            assertReferenced(.class("FixtureClass74")) {
                self.assertReferenced(.enum("CodingKeys"))
            }
            assertReferenced(.class("FixtureClass75")) {
                self.assertReferenced(.enum("CodingKeys"))
            }
            assertReferenced(.class("FixtureClass203")) {
                self.assertReferenced(.enum("CodingKeys"))
            }
            assertReferenced(.class("FixtureClass111")) {
                self.assertReferenced(.enum("CodingKeys"))
            }
            assertReferenced(.class("FixtureClass76")) {
                // Not referenced because the enclosing class does not conform to Codable.
                self.assertNotReferenced(.enum("CodingKeys"))
            }
            assertReferenced(.struct("FixtureClass120")) {
                self.assertReferenced(.enum("CodingKeys"))
            }
            assertReferenced(.struct("FixtureClass218")) {
                self.assertReferenced(.enum("CodingKeys"))
            }
        }
    }

    func testRequiredInitInSubclass() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass77Base")) {
                self.assertReferenced(.functionConstructor("init(a:)"))
                self.assertReferenced(.functionConstructor("init(b:)"))
            }
            assertReferenced(.class("FixtureClass77")) {
                self.assertReferenced(.functionConstructor("init(a:)"))
                self.assertReferenced(.functionConstructor("init(b:)"))
                self.assertReferenced(.functionConstructor("init(c:)"))
            }
        }
    }

    func testRetainsExternalTypeExtension() throws {
        try analyze {
            assertReferenced(.extensionProtocol("Sequence"))
            assertReferenced(.extensionStruct("Array"))
            assertReferenced(.extensionClass("NumberFormatter"))
        }
    }

    func testRetainsExtendedTypeAlias() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.typealias("Fixture214TypeAlias"))
            assertReferenced(.class("FixtureClass214")) {
                self.assertReferenced(.varInstance("someExtensionProperty"))
            }
        }
    }

    func testRetainsExtendedExternalTypeAlias() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.typealias("Fixture215TypeAlias"))
            assertReferenced(.extensionStruct("Int")) {
                self.assertReferenced(.varInstance("someExtensionProperty"))
            }
        }
    }

    func testRetainsExtendedProtocolTypeAlias() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.typealias("Fixture216TypeAlias"))
            assertReferenced(.extensionProtocol("FixtureProtocol216")) {
                self.assertReferenced(.varInstance("someExtensionProperty"))
            }
        }
    }

    func testRetainsInferredAssociatedType() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct120")) {
                self.assertReferenced(.enum("AssociatedType"))
            }
            assertReferenced(.protocol("FixtureProtocol120")) {
                self.assertReferenced(.associatedtype("AssociatedType"))
            }
        }
    }

    func testRetainsAssociatedTypeTypeAlias() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass87Usage")) {
                self.assertReferenced(.functionMethodInstance("somePublicFunction()"))
            }
            assertReferenced(.class("Fixture87StateMachine")) {
                self.assertReferenced(.functionMethodInstance("someFunction(_:)"))
            }
            assertReferenced(.struct("Fixture87AssociatedType"))
            assertReferenced(.protocol("Fixture87State")) {
                self.assertReferenced(.associatedtype("AssociatedType"))
            }
            assertReferenced(.enum("Fixture87MyState")) {
                self.assertReferenced(.typealias("AssociatedType"))
            }
        }
    }

    func testRetainsExternalAssociatedTypeTypeAlias() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("Fixture110")) {
                self.assertReferenced(.typealias("Value"))
            }
        }
    }

    func testUnusedAssociatedType() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass88Usage")) {
                self.assertReferenced(.functionMethodInstance("somePublicFunction()"))
            }
            assertReferenced(.class("Fixture88StateMachine")) {
                self.assertReferenced(.functionMethodInstance("someFunction()"))
            }
            assertReferenced(.protocol("Fixture88State")) {
                self.assertNotReferenced(.associatedtype("AssociatedType"))
            }
            assertReferenced(.enum("Fixture88MyState")) {
                self.assertNotReferenced(.typealias("AssociatedType"))
            }
        }
    }

    func testIsolatedCyclicRootReferences() throws {
        try analyze(retainPublic: true) {
            assertNotReferenced(.class("FixtureClass90"))
            assertNotReferenced(.class("FixtureClass91"))
        }
    }

    func testRetainsUsedProtocolThatInheritsForeignProtocol() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol96")) {
                self.assertReferenced(.varInstance("usedValue"))
                self.assertNotReferenced(.varInstance("unusedValue"))
            }
            assertReferenced(.extensionProtocol("FixtureProtocol96")) {
                self.assertReferenced(.functionOperatorInfix("<(_:_:)"))
            }
            assertReferenced(.class("FixtureClass96")) {
                self.assertReferenced(.varInstance("usedValue"))
                self.assertNotReferenced(.varInstance("unusedValue"))
            }
        }
    }

    func testRetainsProtocolMethodsImplementedInSuperclasss() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol97")) {
                self.assertReferenced(.functionMethodInstance("someProtocolMethod1()"))
                self.assertReferenced(.functionMethodInstance("someProtocolMethod2()"))
                self.assertReferenced(.varInstance("someProtocolVar"))
                self.assertNotReferenced(.functionMethodInstance("someUnusedProtocolMethod()"))
            }
            assertReferenced(.class("FixtureClass97"))
            assertReferenced(.class("FixtureClass97Base1")) {
                self.assertReferenced(.functionMethodInstance("someProtocolMethod1()"))
                self.assertReferenced(.varInstance("someProtocolVar"))
            }
            assertReferenced(.class("FixtureClass97Base2")) {
                self.assertReferenced(.functionMethodInstance("someProtocolMethod2()"))
                self.assertNotReferenced(.functionMethodInstance("someUnusedProtocolMethod()"))
            }
        }
    }

    func testProtocolMethodsImplementedOnlyInExtension() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol115"))
            assertNotRedundantProtocol("FixtureProtocol115")
            assertReferenced(.extensionProtocol("FixtureProtocol115")) {
                self.assertReferenced(.functionMethodInstance("used()"))
                self.assertNotReferenced(.functionMethodInstance("unused()"))
            }
        }
    }

    func testPublicProtocolMethodImplementedOnlyInExtension() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol116"))
            assertNotRedundantProtocol("FixtureProtocol116")
            assertReferenced(.extensionProtocol("FixtureProtocol116")) {
                self.assertReferenced(.functionMethodInstance("used()"))
                self.assertNotReferenced(.functionMethodInstance("unused()"))
            }
        }
    }

    func testProtocolImplementInClassAndExtension() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass98")) {
                self.assertReferenced(.functionMethodInstance("method1()"))
                self.assertReferenced(.functionMethodInstance("method2()"))
            }
            assertReferenced(.protocol("FixtureProtocol98")) {
                self.assertReferenced(.functionMethodInstance("method1()"))
                self.assertReferenced(.functionMethodInstance("method2()"))
            }
        }
    }

    func testConstrainedProtocolExtensionSatisfiesProtocolRequirement() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol1021A")) {
                self.assertReferenced(.varInstance("value"))
            }
            assertReferenced(.protocol("FixtureProtocol1021B"))
            assertReferenced(.extensionProtocol("FixtureProtocol1021B")) {
                // The extension's value satisfies FixtureProtocol1021A's requirement
                self.assertReferenced(.varInstance("value"))
            }
        }
    }

    func testDoesNotRetainProtocolMembersImplementedByExternalType() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol110")) {
                self.assertReferenced(.functionMethodInstance("sync(execute:)"))
                self.assertNotReferenced(.functionMethodInstance("async(execute:)"))
                self.assertReferenced(.functionMethodInstance("customImplementedByExtensionUsed()"))
                self.assertNotReferenced(.functionMethodInstance("customImplementedByExtensionUnused()"))
            }
            assertReferenced(.extensionProtocol("FixtureProtocol110")) {
                self.assertReferenced(.functionMethodInstance("customImplementedByExtensionUsed()"))
                self.assertNotReferenced(.functionMethodInstance("customImplementedByExtensionUnused()"))
            }
            assertReferenced(.extensionClass("DispatchQueue")) {
                // Unused because DispatchQueue already provides an implementation, it appears Swift
                // always favors the original implementation.
                self.assertNotReferenced(.functionMethodInstance("sync(execute:)"))
                self.assertNotReferenced(.functionMethodInstance("async(execute:)"))
                self.assertReferenced(.functionMethodInstance("customImplementedByExtensionUsed()"))
                self.assertNotReferenced(.functionMethodInstance("customImplementedByExtensionUnused()"))
            }
        }
    }

    func testDoesNotRetainDescendantsOfUnusedDeclaration() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass99Outer")) {
                self.assertNotReferenced(.class("FixtureClass99"))
            }
        }
    }

    func testNestedDeclarations() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass102")) {
                self.assertReferenced(.functionMethodInstance("nested1()"))
                self.assertReferenced(.functionMethodInstance("nested2()"))
            }
        }
    }

    func testIdenticallyNamedVarsInStaticAndInstanceScopes() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass95")) {
                self.assertReferenced(.varInstance("someVar"))
                self.assertReferenced(.varStatic("someVar"))
            }
        }
    }

    func testProtocolConformingMembersAreRetained() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass27")) {
                self.assertReferenced(.functionMethodInstance("protocolMethod()"))
                self.assertReferenced(.functionMethodClass("staticProtocolMethod()"))
                self.assertReferenced(.varClass("staticProtocolVar"))
            }
            assertReferenced(.protocol("FixtureProtocol27"))
            assertReferenced(.class("FixtureClass28")) {
                self.assertReferenced(.functionMethodStatic("overrideStaticProtocolMethod()"))
                self.assertReferenced(.varStatic("overrideStaticProtocolVar"))
            }
            assertReferenced(.class("FixtureClass28Base")) {
                self.assertReferenced(.functionMethodClass("overrideStaticProtocolMethod()"))
                self.assertReferenced(.varClass("overrideStaticProtocolVar"))
            }
            assertReferenced(.protocol("FixtureProtocol28"))
        }
    }

    func testProtocolConformedByStaticMethodOutsideExtension() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass64")) // public
            assertReferenced(.class("FixtureClass65")) // retained by FixtureClass64
            assertReferenced(.functionOperatorInfix("==(_:_:)")) // Equatable
        }
    }

    func testClassRetainedByUnusedInstanceVariable() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass71")) {
                self.assertNotReferenced(.varInstance("someVar"))
            }
            assertNotReferenced(.class("FixtureClass72"))
        }
    }

    func testStaticPropertyDeclaredWithCompositeValuesIsNotRetained() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass38")) {
                self.assertNotReferenced(.varStatic("propertyA"))
                self.assertNotReferenced(.varStatic("propertyB"))
            }
        }
    }

    func testRetainImplicitDeclarations() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct2")) {
                self.assertReferenced(.functionConstructor("init(someVar:)"))
            }
        }
    }

    func testRetainsSynthesizedEquatableProperties() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("SynthesizedEqualityValue")) {
                self.assertReferenced(.varInstance("number"))
                self.assertNotAssignOnlyProperty(.varInstance("number"))
                self.assertReferenced(.varInstance("label"))
                self.assertNotAssignOnlyProperty(.varInstance("label"))
            }
            assertReferenced(.struct("ManualEqualityValue")) {
                self.assertAssignOnlyProperty(.varInstance("ignored"))
            }
            assertReferenced(.struct("ExtensionEqualityValue")) {
                self.assertAssignOnlyProperty(.varInstance("ignored"))
            }
            assertReferenced(.struct("DefaultEqualityValue")) {
                self.assertAssignOnlyProperty(.varInstance("ignored"))
            }
            assertReferenced(.struct("GlobalEqualityValue")) {
                self.assertAssignOnlyProperty(.varInstance("ignored"))
            }
            assertReferenced(.struct("ExternalDefaultEqualityValue")) {
                self.assertAssignOnlyProperty(.varInstance("ignored"))
            }
            assertReferenced(.struct("ExtendedDefaultEqualityValue")) {
                self.assertAssignOnlyProperty(.varInstance("ignored"))
            }
            assertReferenced(.struct("ConstructedOnlyEqualityValue")) {
                self.assertAssignOnlyProperty(.varInstance("ignored"))
                self.assertNotAssignOnlyProperty(.varInstance("used"))
            }
            for name in ["GenericEqualityValue", "LibraryEqualityValue", "NestedEqualityLeaf", "ClosureEqualityValue", "DictionaryEqualityKey"] {
                assertReferenced(.struct(name)) {
                    self.assertNotAssignOnlyProperty(.varInstance("value"))
                }
            }
            assertNotReferenced(.struct("UnreachableEqualityValue"))
        }
    }

    #if os(macOS)
        func testRetainsNestedSwiftUIProjectedState() throws {
            try analyze(retainPublic: true) {
                assertReferenced(.struct("NestedProjectionPreviews")) {
                    self.assertReferenced(.struct("FirstPreview")) {
                        self.assertReferenced(.varInstance("firstSelection"))
                    }
                    self.assertReferenced(.struct("SecondPreview")) {
                        self.assertReferenced(.varInstance("secondSelection"))
                        self.assertNotReferenced(.varInstance("unusedSelection"))
                    }
                }
            }
        }
    #endif

    func testRetainsPropertyWrappers() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("Fixture111")) {
                self.assertReferenced(.varInstance("someVar"))
                self.assertReferenced(.functionMethodStatic("buildBlock()"))
            }
            assertReferenced(.class("Fixture111Wrapper")) {
                self.assertReferenced(.varInstance("wrappedValue"))
                self.assertReferenced(.varInstance("projectedValue"))
            }
        }
    }

    func testRetainsStringInterpolationAppendInterpolation() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.extensionStruct("DefaultStringInterpolation")) {
                self.assertReferenced(.functionMethodInstance("appendInterpolation(test:)"))
            }
        }
    }

    func testRetainsProtocolsViaCompositeTypealias() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("Fixture200"))
            assertReferenced(.protocol("Fixture201"))
            assertReferenced(.typealias("Fixture202"))
        }
    }

    func testCircularTypeInheritance() throws {
        try analyze {
            // Intentionally blank.
            // Fixture contains a circular reference that shouldn't cause a stack overflow.
        }
    }

    func testRetainsResultBuilderMethods() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass130")) {
                self.assertReferenced(.functionMethodStatic("buildExpression(_:)"))
                self.assertReferenced(.functionMethodStatic("buildOptional(_:)"))
                self.assertReferenced(.functionMethodStatic("buildEither(first:)"))
                self.assertReferenced(.functionMethodStatic("buildEither(second:)"))
                self.assertReferenced(.functionMethodStatic("buildArray(_:)"))
                self.assertReferenced(.functionMethodStatic("buildBlock(_:)"))
                self.assertReferenced(.functionMethodStatic("buildFinalResult(_:)"))
                self.assertReferenced(.functionMethodStatic("buildLimitedAvailability(_:)"))
            }
        }
    }

    func testRetainsCallAsFunction() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct1")) {
                self.assertReferenced(.functionMethodInstance("callAsFunction(_:)"))
            }
        }
    }

    func testDoesNotRetainLazyProperty() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass36")) {
                self.assertNotReferenced(.varInstance("someLazyVar"))
                self.assertNotReferenced(.varInstance("someVar"))
            }
        }
    }

    func testRetainsDynamicMemberLookupSubscript() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct7")) {
                self.assertReferenced(.functionSubscript("subscript(dynamicMember:)"))
                self.assertNotReferenced(.functionSubscript("subscript(_:)"))
            }
        }
    }

    func testRetainsDynamicMemberLookupSubscriptInExternalTypeExtension() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.extensionEnum("AttributeDynamicLookup")) {
                self.assertReferenced(.functionSubscript("subscript(dynamicMember:)"))
            }
        }
    }

    func testRetainsCodableProperties() throws {
        try analyze(
            retainPublic: true,
            retainCodableProperties: false,
            retainAssignOnlyProperties: false
        ) {
            assertReferenced(.struct("FixtureStruct14")) {
                self.assertNotReferenced(.functionConstructor("init(unused:)"))
                self.assertAssignOnlyProperty(.varInstance("unused"))
            }
        }

        try analyze(
            retainPublic: true,
            retainCodableProperties: true
        ) {
            assertReferenced(.struct("FixtureStruct14")) {
                self.assertNotReferenced(.functionConstructor("init(unused:)"))
                self.assertReferenced(.varInstance("unused"))
                self.assertNotAssignOnlyProperty(.varInstance("unused"))
            }
        }
    }

    func testRetainsEncodableProperties() throws {
        try analyze(
            retainPublic: true,
            retainEncodableProperties: false,
            retainAssignOnlyProperties: false
        ) {
            assertReferenced(.struct("FixtureStruct15")) {
                self.assertNotReferenced(.functionConstructor("init(unused:)"))
                self.assertAssignOnlyProperty(.varInstance("unused"))
            }
        }

        try analyze(
            retainPublic: true,
            retainEncodableProperties: true
        ) {
            assertReferenced(.struct("FixtureStruct15")) {
                self.assertNotReferenced(.functionConstructor("init(unused:)"))
                self.assertReferenced(.varInstance("unused"))
                self.assertNotAssignOnlyProperty(.varInstance("unused"))
            }
        }
    }

    func testRetainsEquatableProperties() throws {
        try analyze(
            retainPublic: true,
            retainEquatableProperties: false,
            retainAssignOnlyProperties: false
        ) {
            assertReferenced(.struct("FixtureStruct222")) {
                self.assertNotReferenced(.functionConstructor("init(unused:)"))
                self.assertAssignOnlyProperty(.varInstance("unused"))
            }
        }

        try analyze(
            retainPublic: true,
            retainEquatableProperties: true
        ) {
            assertReferenced(.struct("FixtureStruct222")) {
                self.assertNotReferenced(.functionConstructor("init(unused:)"))
                self.assertReferenced(.varInstance("unused"))
                self.assertNotAssignOnlyProperty(.varInstance("unused"))
            }

            assertReferenced(.struct("FixtureStruct223")) {
                self.assertNotReferenced(.functionConstructor("init(unused:)"))
                self.assertReferenced(.varInstance("unused"))
                self.assertNotAssignOnlyProperty(.varInstance("unused"))
            }

            assertReferenced(.class("FixtureClass222")) {
                self.assertAssignOnlyProperty(.varInstance("unused"))
            }
        }
    }

    func testRetainsHashableProperties() throws {
        try analyze(
            retainPublic: true,
            retainHashableProperties: false,
            retainAssignOnlyProperties: false
        ) {
            assertReferenced(.struct("FixtureStruct224")) {
                self.assertNotReferenced(.functionConstructor("init(unused:)"))
                self.assertAssignOnlyProperty(.varInstance("unused"))
            }
        }

        try analyze(
            retainPublic: true,
            retainHashableProperties: true
        ) {
            assertReferenced(.struct("FixtureStruct224")) {
                self.assertNotReferenced(.functionConstructor("init(unused:)"))
                self.assertReferenced(.varInstance("unused"))
                self.assertNotAssignOnlyProperty(.varInstance("unused"))
            }
        }
    }

    func testRetainsFilesOption() throws {
        try analyze(retainFiles: [testFixturePath.string]) {
            assertReferenced(.class("FixtureClass100"))
        }

        try analyze(retainFiles: []) {
            assertNotReferenced(.class("FixtureClass100"))
        }
    }

    func testMainActorAnnotation() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass132")) {
                self.assertReferenced(.functionConstructor("init(value:)"))
            }
            assertReferenced(.class("FixtureClass133"))
        }
    }

    // https://github.com/apple/swift/issues/64686
    // https://github.com/peripheryapp/periphery/issues/264
    func testSelfReferencedConstructor() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct3")) {
                self.assertReferenced(.functionConstructor("init(value:)"))
            }
            assertReferenced(.struct("FixtureStruct4")) {
                self.assertReferenced(.functionConstructor("init(value:)"))
            }
            assertReferenced(.struct("FixtureStruct5")) {
                self.assertNotReferenced(.functionConstructor("init(value:)"))
            }
        }
    }

    // https://github.com/apple/swift/issues/56541
    func testStaticMemberUsedAsSubscriptKey() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.enum("FixtureEnum128")) {
                self.assertReferenced(.varStatic("someVar"))
            }
        }
    }

    func testRetainsDynamicReplacement() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct8")) {
                self.assertReferenced(.functionMethodStatic("originalStaticMethod()"))
                self.assertReferenced(.functionMethodStatic("replacementStaticMethod()"))

                self.assertReferenced(.functionMethodInstance("originalMethod()"))
                self.assertReferenced(.functionMethodInstance("replacementMethod()"))

                self.assertReferenced(.varInstance("originalProperty"))
                self.assertReferenced(.varInstance("replacementProperty"))

                self.assertReferenced(.functionSubscript("subscript(original:)"))
                self.assertReferenced(.functionSubscript("subscript(replacement:)"))
            }
        }
    }

    // MARK: - Comment Commands

    func testIgnoreComments() throws {
        // ensure this external module is explicitly indexed so we can tell if it is unused
        let additionalFilesToIndex = [
            FixturesProjectPath.appending("Sources/UnusedModuleFixtures/UnusedModuleDeclaration.swift"),
        ]

        try analyze(retainPublic: true, additionalFilesToIndex: additionalFilesToIndex) {
            assertReferenced(.module("UnusedModuleFixtures"))
            assertReferenced(.class("Fixture113")) {
                self.assertReferenced(.functionMethodInstance("someFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.class("Fixture114")) {
                self.assertReferenced(.functionMethodInstance("referencedFunc()"))
                self.assertReferenced(.functionMethodInstance("someFunc(a:b:c:)")) {
                    self.assertReferenced(.varParameter("b"))
                    self.assertReferenced(.varParameter("c"))
                }
                self.assertReferenced(.functionMethodInstance("protocolFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.protocol("Fixture114Protocol")) {
                self.assertReferenced(.functionMethodInstance("protocolFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.class("FixtureClass116")) {
                self.assertReferenced(.functionMethodInstance("someFunc()"))
                self.assertReferenced(.varInstance("simpleProperty"))
                self.assertReferenced(.varInstance("tuplePropertyA"))
                self.assertReferenced(.varInstance("tuplePropertyB"))
                self.assertReferenced(.varInstance("multiBindingPropertyA"))
                self.assertReferenced(.varInstance("multiBindingPropertyB"))
                self.assertReferenced(.varInstance("assignOnlyProperty"))
                self.assertReferenced(.varInstance("commentWithTrailingDescription"))
                self.assertNotAssignOnlyProperty(.varInstance("assignOnlyProperty"))
            }
            assertReferenced(.class("FixtureClass212")) {
                self.assertReferenced(.functionMethodInstance("protocolFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.class("FixtureClass213")) {
                self.assertReferenced(.functionMethodInstance("someFunc(a:b:c:)")) {
                    self.assertReferenced(.varParameter("b"))
                    self.assertReferenced(.varParameter("c"))
                }
            }
            assertReferenced(.class("Fixture205"))
            assertReferenced(.protocol("Fixture205Protocol"))
            assertNotRedundantProtocol("Fixture205Protocol")

            // Inline ignore comments on properties (issue #941)
            assertReferenced(.class("Fixture310Class")) {
                self.assertReferenced(.varInstance("simplePropertyInlineIgnored"))
                self.assertReferenced(.varInstance("computedPropertyInlineIgnored"))
                self.assertReferenced(.varInstance("computedPropertyWithOpenBraceIgnore"))
            }
            assertReferenced(.protocol("Fixture311Protocol")) {
                self.assertReferenced(.varInstance("protocolPropertyInlineIgnored"))
            }
        }

        // inline comment command tests
        try analyze(retainPublic: false) {
            assertReferenced(.class("Fixture300Class"))
            assertReferenced(.class("Fixture301Class"))

            assertReferenced(.protocol("Fixture302Protocol"))
            assertNotRedundantProtocol("Fixture302Protocol")
            assertReferenced(.protocol("Fixture303Protocol"))
            assertNotRedundantProtocol("Fixture303Protocol")

            assertReferenced(.struct("Fixture304Struct"))
            assertReferenced(.struct("Fixture305Struct"))

            assertReferenced(.extensionProtocol("Fixture306Protocol"))
            assertNotRedundantProtocol("Fixture306Protocol")

            assertReferenced(.enum("Fixture307Enum"))

            assertReferenced(.class("Fixture308Class")) {
                self.assertReferenced(.functionMethodInstance("someFunc()"))
                self.assertReferenced(.functionConstructor("init(string:)"))
            }
        }
    }

    func testIgnoreAllComment() throws {
        try analyze(retainPublic: false) {
            assertReferenced(.class("Fixture115")) {
                self.assertReferenced(.functionMethodInstance("someFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.class("Fixture116"))

            assertNotSuperfluousIgnoreCommand(.class("Fixture115"))
            assertNotSuperfluousIgnoreCommand(.class("Fixture116"))
        }
    }

    func testCommentCommandOverride() throws {
        try analyze(retainPublic: true) {
            // Test relative path override (gets converted to absolute)
            assertOverrides(.class("FixtureClass136"), [
                .location(FilePath.current.pushing("some/other/file.swift"), 12, 34),
                .kind("banana"),
            ])
            // Test absolute path override (stays absolute)
            assertOverrides(.class("FixtureClass137"), [
                .location("/absolute/path/file.swift", 56, 78),
            ])
        }
    }

    func testSuperfluousIgnoreCommand() throws {
        try analyze(retainPublic: true) {
            // These have ignore commands but are actually used, so the ignore is superfluous
            assertSuperfluousIgnoreCommand(.functionFree("superfluouslyIgnoredFunc()"))
            assertSuperfluousIgnoreCommand(.class("SuperfluouslyIgnoredClass"))

            // These have ignore commands and are NOT used, so the ignore is needed
            assertNotSuperfluousIgnoreCommand(.functionFree("correctlyIgnoredFunc()"))
            assertNotSuperfluousIgnoreCommand(.class("CorrectlyIgnoredClass"))

            // The callers should be referenced normally
            assertReferenced(.functionFree("callerOfSuperfluouslyIgnoredFunc()"))
            assertReferenced(.functionFree("useSuperfluouslyIgnoredClass()"))

            // Test ignored declarations within non-ignored parent
            assertReferenced(.class("NonIgnoredParentClass")) {
                // This method is ignored but used by callerMethod - superfluous
                self.assertSuperfluousIgnoreCommand(.functionMethodInstance("superfluouslyIgnoredMethod()"))
                // This method is ignored and not used - correctly ignored
                self.assertNotSuperfluousIgnoreCommand(.functionMethodInstance("correctlyIgnoredMethod()"))
                // The caller method should be referenced normally
                self.assertReferenced(.functionMethodInstance("callerMethod()"))
            }

            // Test deeply nested declarations within ignored hierarchy.
            // Internal references between members of an ignored class should NOT
            // make those members appear superfluously ignored.
            assertNotSuperfluousIgnoreCommand(.class("DeeplyNestedIgnoredClass"))
            assertNotSuperfluousIgnoreCommand(.functionMethodInstance("methodA()"))
            assertNotSuperfluousIgnoreCommand(.functionMethodInstance("methodB()"))
            assertNotSuperfluousIgnoreCommand(.functionMethodInstance("methodC()"))

            // Assign-only properties with ignore comments are NOT superfluous
            assertReferenced(.struct("AssignOnlyIgnoreStruct")) {
                self.assertNotSuperfluousIgnoreCommand(.varInstance("assignOnlyIgnored"))
                self.assertReferenced(.varInstance("usedProperty"))
            }

            // Test superfluous ignore for parameters
            assertReferenced(.class("ParameterIgnoreClass")) {
                self.assertReferenced(.functionMethodInstance("superfluousParamIgnore(usedParam:)")) {
                    // Parameter is ignored but actually used - superfluous
                    self.assertSuperfluousIgnoreCommand(.varParameter("usedParam"))
                }
                self.assertReferenced(.functionMethodInstance("correctParamIgnore(unusedParam:)")) {
                    // Parameter is ignored and not used - correctly ignored
                    self.assertNotSuperfluousIgnoreCommand(.varParameter("unusedParam"))
                }
            }
        }

        try analyze(retainPublic: true, superfluousIgnoreComments: false) {
            // Superfluous ignore warnings should be suppressed when disabled.
            assertNotSuperfluousIgnoreCommand(.functionFree("superfluouslyIgnoredFunc()"))
            assertNotSuperfluousIgnoreCommand(.class("SuperfluouslyIgnoredClass"))
        }
    }

    func testSuperfluousIgnoreCommandOnProtocolMember() throws {
        try analyze(retainPublic: true) {
            // Protocol member with ignore that only has related references (from conformances
            // and default implementations) - the ignore is NOT superfluous.
            assertReferenced(.protocol("CorrectlyIgnoredProtocol")) {
                self.assertNotSuperfluousIgnoreCommand(.varInstance("ignoredProperty"))
            }

            // Protocol member with ignore that has normal references (actually used) -
            // the ignore IS superfluous.
            assertReferenced(.protocol("SuperfluouslyIgnoredProtocol")) {
                self.assertSuperfluousIgnoreCommand(.varInstance("superfluousProperty"))
            }
        }
    }

    // MARK: - Swift Testing

    #if canImport(Testing)
        func testRetainsSwiftTestingDeclarations() throws {
            try analyze {
                assertReferenced(.functionFree("swiftTestingFreeFunction()"))

                assertReferenced(.class("SwiftTestingClass")) {
                    self.assertReferenced(.functionMethodInstance("instanceMethod()"))
                    self.assertReferenced(.functionMethodClass("classMethod()"))
                    self.assertReferenced(.functionMethodStatic("staticMethod()"))
                }

                assertReferenced(.struct("SwiftTestingStructWithSuite")) {
                    self.assertReferenced(.functionMethodInstance("instanceMethod()"))
                    self.assertReferenced(.functionMethodStatic("staticMethod()"))
                }

                assertReferenced(.class("SwiftTestingClassWithSuite")) {
                    self.assertReferenced(.functionMethodInstance("instanceMethod()"))
                    self.assertReferenced(.functionMethodClass("classMethod()"))
                    self.assertReferenced(.functionMethodStatic("staticMethod()"))
                }
            }
        }
    #endif

    // MARK: - Assign-only properties

    func testStructImplicitInitializer() throws {
        try analyze(retainPublic: true, retainAssignOnlyProperties: false) {
            assertReferenced(.struct("FixtureStruct13_Codable")) {
                self.assertAssignOnlyProperty(.varInstance("assignOnly"))
            }
            assertReferenced(.struct("FixtureStruct13_NotCodable")) {
                self.assertAssignOnlyProperty(.varInstance("assignOnly"))
                self.assertNotAssignOnlyProperty(.varInstance("used"))
            }
        }

        try analyze(retainPublic: true, retainAssignOnlyProperties: true) {
            assertReferenced(.struct("FixtureStruct13_Codable")) {
                self.assertReferenced(.varInstance("assignOnly"))
                self.assertNotAssignOnlyProperty(.varInstance("assignOnly"))
            }
            assertReferenced(.struct("FixtureStruct13_NotCodable")) {
                self.assertReferenced(.varInstance("assignOnly"))
                self.assertNotAssignOnlyProperty(.varInstance("assignOnly"))
                self.assertReferenced(.varInstance("used"))
                self.assertNotAssignOnlyProperty(.varInstance("used"))
            }
        }
    }

    func testSimplePropertyAssignedButNeverRead() throws {
        try analyze(retainPublic: true, retainAssignOnlyProperties: false) {
            assertReferenced(.class("FixtureClass70")) {
                self.assertAssignOnlyProperty(.varInstance("simpleUnreadVar"))
                self.assertAssignOnlyProperty(.varInstance("simpleUnreadShadowedVar"))
                self.assertAssignOnlyProperty(.varInstance("simpleUnreadVarAssignedMultiple"))
                self.assertAssignOnlyProperty(.varStatic("simpleStaticUnreadVar"))

                self.assertReferenced(.varInstance("complexUnreadVar1"))
                self.assertNotAssignOnlyProperty(.varInstance("complexUnreadVar1"))

                self.assertReferenced(.varInstance("complexUnreadVar2"))
                self.assertNotAssignOnlyProperty(.varInstance("complexUnreadVar2"))

                self.assertReferenced(.varInstance("readVar"))
                self.assertNotAssignOnlyProperty(.varInstance("readVar"))

                self.assertReferenced(.varInstance("ignoredSimpleUnreadVar"))
                self.assertNotAssignOnlyProperty(.varInstance("ignoredSimpleUnreadVar"))

                self.assertReferenced(.varInstance("wrappedProperty"))
                self.assertNotAssignOnlyProperty(.varInstance("wrappedProperty"))
            }
        }

        try analyze(retainPublic: true, retainAssignOnlyProperties: true) {
            assertReferenced(.class("FixtureClass70")) {
                self.assertReferenced(.varInstance("simpleUnreadVar"))
                self.assertNotAssignOnlyProperty(.varInstance("simpleUnreadVar"))

                self.assertReferenced(.varInstance("simpleUnreadShadowedVar"))
                self.assertNotAssignOnlyProperty(.varInstance("simpleUnreadShadowedVar"))

                self.assertReferenced(.varInstance("simpleUnreadVarAssignedMultiple"))
                self.assertNotAssignOnlyProperty(.varInstance("simpleUnreadVarAssignedMultiple"))

                self.assertReferenced(.varStatic("simpleStaticUnreadVar"))
                self.assertNotAssignOnlyProperty(.varStatic("simpleStaticUnreadVar"))

                self.assertReferenced(.varInstance("complexUnreadVar1"))
                self.assertNotAssignOnlyProperty(.varInstance("complexUnreadVar1"))

                self.assertReferenced(.varInstance("complexUnreadVar2"))
                self.assertNotAssignOnlyProperty(.varInstance("complexUnreadVar2"))

                self.assertReferenced(.varInstance("readVar"))
                self.assertNotAssignOnlyProperty(.varInstance("readVar"))

                self.assertReferenced(.varInstance("ignoredSimpleUnreadVar"))
                self.assertNotAssignOnlyProperty(.varInstance("ignoredSimpleUnreadVar"))

                self.assertReferenced(.varInstance("wrappedProperty"))
                self.assertNotAssignOnlyProperty(.varInstance("wrappedProperty"))
            }
        }
    }

    func testSimpleAssignOnlyPropertyNameConflict() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass131")) {
                self.assertAssignOnlyProperty(.varInstance("someProperty"))
                self.assertReferenced(.varStatic("someProperty"))
            }
        }
    }

    func testRetainsAssignOnlyPropertyTypes() throws {
        try analyze(
            retainPublic: true,
            retainAssignOnlyProperties: false,
            retainAssignOnlyPropertyTypes: ["CustomType", "(CustomType, String)", "Swift.Double"]
        ) {
            assertReferenced(.class("FixtureClass123")) {
                self.assertReferenced(.varInstance("retainedSimpleProperty"))
                self.assertNotAssignOnlyProperty(.varInstance("retainedSimpleProperty"))

                self.assertReferenced(.varInstance("retainedSimplePropertyImplicitUnwrap"))
                self.assertNotAssignOnlyProperty(.varInstance("retainedSimplePropertyImplicitUnwrap"))

                self.assertReferenced(.varInstance("retainedModulePrefixedProperty"))
                self.assertNotAssignOnlyProperty(.varInstance("retainedModulePrefixedProperty"))

                self.assertReferenced(.varInstance("retainedTupleProperty"))
                self.assertNotAssignOnlyProperty(.varInstance("retainedTupleProperty"))

                self.assertReferenced(.varInstance("retainedDestructuredPropertyA"))
                self.assertNotAssignOnlyProperty(.varInstance("retainedDestructuredPropertyA"))

                self.assertReferenced(.varInstance("retainedMultipleBindingPropertyA"))
                self.assertNotAssignOnlyProperty(.varInstance("retainedMultipleBindingPropertyA"))

                #if canImport(Combine)
                    self.assertReferenced(.varInstance("retainedAnyCancellable"))
                #endif

                self.assertAssignOnlyProperty(.varInstance("notRetainedSimpleProperty"))
                self.assertAssignOnlyProperty(.varInstance("notRetainedModulePrefixedProperty"))
                self.assertAssignOnlyProperty(.varInstance("notRetainedTupleProperty"))
                self.assertAssignOnlyProperty(.varInstance("notRetainedDestructuredPropertyB"))
                self.assertAssignOnlyProperty(.varInstance("notRetainedMultipleBindingPropertyB"))
            }
        }
    }

    // MARK: - Unused Parameters

    func testRetainsParamUsedInOverriddenMethod() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass101Base")) {
                // Not used and not overridden.
                self.assertReferenced(.functionMethodInstance("func1(param:)")) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // The param is used.
                self.assertReferenced(.functionMethodInstance("func2(param:)")) {
                    self.assertUsedParameter("param")
                }

                // Used in override.
                self.assertReferenced(.functionMethodInstance("func3(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }

                // Used in override.
                // func4(param: String)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 14)) {
                    self.assertReferenced(.varParameter("param"))
                }

                // Not used in any function.
                // func4(param: Int)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 17)) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // Not used in any function.
                self.assertReferenced(.functionMethodInstance("func5(param:)")) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // Overridden in multiple subclass branches.
                self.assertReferenced(.functionMethodInstance("func7(param1:param2:)")) {
                    self.assertReferenced(.varParameter("param1"))
                    self.assertNotReferenced(.varParameter("param2"))
                }
            }

            assertReferenced(.class("FixtureClass101Subclass1")) {
                // Used in base.
                self.assertReferenced(.functionMethodInstance("func2(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }

                // The param is used.
                self.assertReferenced(.functionMethodInstance("func3(param:)")) {
                    self.assertUsedParameter("param")
                }

                // Not used in any function.
                // func4(param: Int)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 36)) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // Overridden in multiple subclass branches.
                self.assertReferenced(.functionMethodInstance("func7(param1:param2:)")) {
                    self.assertUsedParameter("param1")
                    self.assertNotReferenced(.varParameter("param2"))
                }
            }

            assertReferenced(.class("FixtureClass101Subclass2")) {
                // The param is used.
                // func4(param: String)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 44)) {
                    self.assertUsedParameter("param")
                }

                // Not used in any function.
                // func4(param: Int)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 48)) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // Not used in any function.
                self.assertReferenced(.functionMethodInstance("func5(param:)")) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // Overridden in multiple subclass branches.
                self.assertReferenced(.functionMethodInstance("func7(param1:param2:)")) {
                    self.assertReferenced(.varParameter("param1"))
                    self.assertNotReferenced(.varParameter("param2"))
                }
            }

            assertReferenced(.class("FixtureClass101Subclass3")) {
                // Overridden in multiple subclass branches.
                self.assertReferenced(.functionMethodInstance("func7(param1:param2:)")) {
                    self.assertReferenced(.varParameter("param1"))
                    self.assertNotReferenced(.varParameter("param2"))
                }
            }

            assertReferenced(.class("FixtureClass101InheritForeignBase")) {
                // Overrides foreign function.
                self.assertReferenced(.functionMethodInstance("isEqual(_:)")) {
                    self.assertReferenced(.varParameter("object"))
                }
            }

            assertReferenced(.class("FixtureClass101InheritForeignSubclass1")) {
                // Overrides foreign function.
                self.assertReferenced(.functionMethodInstance("isEqual(_:)")) {
                    self.assertReferenced(.varParameter("object"))
                }
            }
        }
    }

    func testRetainsForeignProtocolParametersInSubclass() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass109")) {
                self.assertReferenced(.functionMethodInstance("copy(with:)")) {
                    self.assertReferenced(.varParameter("zone"))
                }
            }
            assertReferenced(.class("FixtureClass109Subclass")) {
                self.assertReferenced(.functionMethodInstance("copy(with:)")) {
                    self.assertReferenced(.varParameter("zone"))
                }
            }
        }
    }

    func testRetainsForeignProtocolParameters() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass103")) {
                self.assertReferenced(.functionConstructor("init(from:)")) {
                    self.assertReferenced(.varParameter("decoder"))
                }
            }
            assertReferenced(.class("FixtureClass103")) {
                self.assertReferenced(.functionMethodInstance("encode(to:)")) {
                    self.assertReferenced(.varParameter("encoder"))
                }
            }
        }
    }

    func testRetainUnusedProtocolFuncParams() throws {
        try analyze(
            retainPublic: true,
            retainUnusedProtocolFuncParams: true
        ) {
            assertReferenced(.protocol("FixtureProtocol107")) {
                self.assertReferenced(.functionMethodInstance("myFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.extensionProtocol("FixtureProtocol107")) {
                self.assertReferenced(.functionMethodInstance("myFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.class("FixtureClass107Class1")) {
                self.assertReferenced(.functionMethodInstance("myFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.class("FixtureClass107Class2")) {
                self.assertReferenced(.functionMethodInstance("myFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
        }
    }

    func testRetainsPublicAPIParameters() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass234")) {
                self.assertReferenced(.functionMethodInstance("publicFunc(unused:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("publicFuncReadingParam(used:)")) {
                    self.assertUsedParameter("used")
                }
                self.assertReferenced(.functionMethodInstance("internalFunc(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("overriddenFunc(unused:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
            }
            assertReferenced(.class("FixtureClass234Subclass")) {
                self.assertReferenced(.functionMethodInstance("overriddenFunc(unused:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
            }
            assertReferenced(.protocol("FixtureProtocol234")) {
                self.assertReferenced(.functionMethodInstance("requirement(unused:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
            }
            assertReferenced(.class("FixtureClass234Witness")) {
                self.assertReferenced(.functionMethodInstance("requirement(unused:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
            }
            assertReferenced(.protocol("FixtureProtocol234Internal")) {
                self.assertReferenced(.functionMethodInstance("internalRequirement(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
            }
            assertReferenced(.class("FixtureClass234InternalWitness")) {
                self.assertReferenced(.functionMethodInstance("internalRequirement(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
            }
        }
    }

    func testRetainsFunctionValueParameters() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass237")) {
                self.assertReferenced(.functionMethodInstance("assignedFunc(unused:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("passedFunc(_:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodStatic("staticValueFunc(unused:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("overriddenFunc(_:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("passedFuncReadingParam(_:)")) {
                    self.assertUsedParameter("used")
                }
                self.assertReferenced(.functionMethodInstance("calledFunc(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("closureWrappedFunc(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionConstructor("init(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionSubscript("subscript(_:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
            }
            assertReferenced(.class("FixtureClass237Subclass")) {
                self.assertReferenced(.functionMethodInstance("overriddenFunc(_:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
            }
            assertReferenced(.protocol("FixtureProtocol237")) {
                self.assertReferenced(.functionMethodInstance("valueRequirement(_:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("calledRequirement(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
            }
            assertReferenced(.class("FixtureClass237Witness")) {
                self.assertReferenced(.functionMethodInstance("valueRequirement(_:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("calledRequirement(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
            }
        }
    }

    func testRetainsExternalWitnessParameters() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct238")) {
                self.assertReferenced(.functionMethodInstance("_failEarlyRangeCheck(_:bounds:)")) {
                    self.assertReferenced(.varParameter("index"))
                    self.assertReferenced(.varParameter("bounds"))
                }
                self.assertReferenced(.functionMethodInstance("distance(from:to:)")) {
                    self.assertReferenced(.varParameter("start"))
                    self.assertReferenced(.varParameter("end"))
                }
                self.assertReferenced(.functionMethodInstance("helper(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("_helper(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
            }
            assertReferenced(.struct("FixtureStruct238Extension")) {
                self.assertReferenced(.functionMethodInstance("_failEarlyRangeCheck(_:bounds:)")) {
                    self.assertReferenced(.varParameter("index"))
                    self.assertReferenced(.varParameter("bounds"))
                }
            }
            assertReferenced(.struct("FixtureStruct238Refined")) {
                self.assertReferenced(.functionMethodInstance("_failEarlyRangeCheck(_:bounds:)", line: 50)) {
                    self.assertReferenced(.varParameter("range"))
                    self.assertReferenced(.varParameter("bounds"))
                }
                self.assertReferenced(.functionMethodInstance("_failEarlyRangeCheck(_:bounds:)", line: 53)) {
                    self.assertUsedParameter("index")
                    self.assertUsedParameter("bounds")
                }
            }
            assertReferenced(.struct("FixtureStruct238Hashable")) {
                self.assertReferenced(.functionMethodInstance("hash(into:)")) {
                    self.assertReferenced(.varParameter("hasher"))
                }
                self.assertReferenced(.functionMethodInstance("_rawHashValue(seed:)")) {
                    self.assertReferenced(.varParameter("seed"))
                }
            }
            assertReferenced(.struct("FixtureStruct238Internal")) {
                self.assertReferenced(.functionMethodInstance("internalRequirement(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("_failEarlyRangeCheck(_:bounds:)")) {
                    self.assertNotReferenced(.varParameter("index"))
                    self.assertNotReferenced(.varParameter("bounds"))
                }
            }
        }
    }

    func testReportsNoRetainSPIParameters() throws {
        try analyze(retainPublic: true, noRetainSPI: ["Internal"]) {
            assertReferenced(.class("FixtureClass235")) {
                self.assertReferenced(.functionMethodInstance("listedSPIFunc(unused:)")) {
                    self.assertNotReferenced(.varParameter("unused"))
                }
                self.assertReferenced(.functionMethodInstance("unlistedSPIFunc(unused:)")) {
                    self.assertReferenced(.varParameter("unused"))
                }
            }
        }
    }

    func testRetainsProtocolParameters() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol104")) {
                // Used in a conformance.
                self.assertReferenced(.functionMethodInstance("func1(param1:param2:)")) {
                    self.assertReferenced(.varParameter("param1"))
                }

                // Not used in any conformance.
                self.assertReferenced(.functionMethodInstance("func1(param1:param2:)")) {
                    self.assertNotReferenced(.varParameter("param2"))
                }

                // Not used in any conformance.
                self.assertReferenced(.functionMethodInstance("func2(param:)")) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // Used in the extension.
                self.assertReferenced(.functionMethodInstance("func3(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }

                // Unused in extension, but used in conformance.
                // func4(param: String)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 11)) {
                    self.assertReferenced(.varParameter("param"))
                }

                // Unused.
                // func4(param: Int)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 13)) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // Used in a conformance.
                self.assertReferenced(.functionMethodStatic("func5(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }

                // Used in a override.
                self.assertReferenced(.functionMethodInstance("func6(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }

            assertReferenced(.extensionProtocol("FixtureProtocol104")) {
                // The param is used.
                self.assertReferenced(.functionMethodInstance("func3(param:)")) {
                    self.assertUsedParameter("param")
                }

                // Used in a conformance by another class.
                // func4(param: String)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 27)) {
                    self.assertReferenced(.varParameter("param"))
                }

                // Unused.
                // func4(param: Int)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 28)) {
                    self.assertNotReferenced(.varParameter("param"))
                }
            }

            assertReferenced(.class("FixtureClass104Class1")) {
                // Used in a conformance by another class.
                self.assertReferenced(.functionMethodInstance("func1(param1:param2:)")) {
                    self.assertReferenced(.varParameter("param1"))
                }

                // Not used in any conformance.
                self.assertReferenced(.functionMethodInstance("func1(param1:param2:)")) {
                    self.assertNotReferenced(.varParameter("param2"))
                }

                // Not used in any conformance.
                self.assertReferenced(.functionMethodInstance("func2(param:)")) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // The param is used.
                self.assertReferenced(.functionMethodStatic("func5(param:)")) {
                    self.assertUsedParameter("param")
                }

                // Used in a override.
                self.assertReferenced(.functionMethodInstance("func6(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }

                // The param is explicitly ignored.
                self.assertReferenced(.functionMethodInstance("func7(_:)")) {
                    self.assertUsedParameter("_")
                }
            }

            assertReferenced(.class("FixtureClass104Class2")) {
                // The param is used.
                self.assertReferenced(.functionMethodInstance("func1(param1:param2:)")) {
                    self.assertUsedParameter("param1")
                }

                // Not used in any conformance.
                self.assertReferenced(.functionMethodInstance("func1(param1:param2:)")) {
                    self.assertNotReferenced(.varParameter("param2"))
                }

                // Not used in any conformance.
                self.assertReferenced(.functionMethodInstance("func2(param:)")) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // The param is used.
                // func4(param: String)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 50)) {
                    self.assertUsedParameter("param")
                }

                // Unused.
                // func4(param: Int)
                self.assertReferenced(.functionMethodInstance("func4(param:)", line: 54)) {
                    self.assertNotReferenced(.varParameter("param"))
                }

                // The param is used.
                self.assertReferenced(.functionMethodStatic("func5(param:)")) {
                    self.assertUsedParameter("param")
                }

                // Used in a override.
                self.assertReferenced(.functionMethodInstance("func6(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }

                // The param is explicitly ignored.
                self.assertReferenced(.functionMethodInstance("func7(_:)")) {
                    self.assertUsedParameter("_")
                }
            }

            assertReferenced(.class("FixtureClass104Class3")) {
                // The param is used.
                self.assertReferenced(.functionMethodInstance("func6(param:)")) {
                    self.assertUsedParameter("param")
                }
            }
        }
    }

    func testRetainsOpenClassParameters() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass112")) {
                self.assertReferenced(.functionMethodInstance("doSomething(with:)")) {
                    self.assertReferenced(.varParameter("value"))
                }
            }
        }
    }

    func testIgnoreUnusedParamInUnusedFunction() throws {
        try analyze {
            assertNotReferenced(.class("FixtureClass105"))
        }
    }

    func testRetainsFunctionParametersOnProtocolMembersImplementedByExternalType() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol125")) {
                self.assertReferenced(.functionMethodInstance("object(forKey:)")) {
                    self.assertReferenced(.varParameter("key"))
                }
            }
        }
    }

    func testRetainsFunctionParametersOnUnimplementedProtocolMembers() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.protocol("FixtureProtocol126")) {
                self.assertReferenced(.functionMethodInstance("unimplementedFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
            assertReferenced(.extensionProtocol("FixtureProtocol126")) {
                self.assertReferenced(.functionMethodInstance("unimplementedFunc(param:)")) {
                    self.assertReferenced(.varParameter("param"))
                }
            }
        }
    }

    func testCustomConstructorWithLiteral() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.extensionStruct("Array")) {
                self.assertReferenced(.functionConstructor("init(title:)"))
            }
        }
    }

    func testRetainsInitializerCalledOnTypeAlias() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass219")) {
                self.assertReferenced(.functionConstructor("init(foo:)"))
            }
        }
    }

    func testDoesNotRetainSPIMembers() throws {
        try analyze(retainPublic: true, noRetainSPI: ["STP"]) {
            assertReferenced(.class("FixtureClass220")) {
                self.assertReferenced(.functionMethodInstance("publicFunc()"))
                self.assertNotReferenced(.functionMethodInstance("stpSpiFunc()"))
                self.assertReferenced(.functionMethodInstance("otherSpiFunc()"))
            }
            assertNotReferenced(.struct("FixtureStruct220"))
            assertReferenced(.struct("FixtureStruct221"))
        }
    }

    // MARK: - Inherited Initializers

    func testRetainsSuperclassInitializerCalledOnSubclass() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass221Parent")) {
                self.assertReferenced(.functionConstructor("init(param:)"))
            }
            assertReferenced(.class("FixtureClass221Child"))
        }
    }

    func testConfidenceLikelyForStringLiteralNames() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass223")) {
                self.assertNotReferenced(.functionMethodInstance("namedInReflection()"))
                self.assertConfidence(.functionMethodInstance("namedInReflection()"), .likely)
                self.assertConfidence(.functionMethodInstance("namedInSelectorString()"), .likely)
                self.assertNotReferenced(.varInstance("comparedAgainstMirrorLabel"))
                self.assertConfidence(.varInstance("comparedAgainstMirrorLabel"), .likely)
                // A bare literal does not look anything up, so a pure-Swift function it names stays certain.
                self.assertNotReferenced(.functionMethodInstance("namedInBareLiteral()"))
                self.assertConfidence(.functionMethodInstance("namedInBareLiteral()"), .certain)
                // Used-but-not-compared control: named in a reflection call and called, so it is not reported.
                self.assertReferenced(.functionMethodInstance("usedAndNamed()"))
                self.assertNotReferenced(.functionMethodInstance("notNamedAnywhere()"))
                self.assertConfidence(.functionMethodInstance("notNamedAnywhere()"), .certain)
                self.assertNotReferenced(.functionMethodInstance("namedInProse()"))
                self.assertConfidence(.functionMethodInstance("namedInProse()"), .certain)
                self.assertReferenced(.functionMethodInstance("take(namedParameter:)")) {
                    // A parameter cannot be looked up by name at run time.
                    self.assertConfidence(.varParameter("namedParameter"), .certain)
                }
            }
        }
    }

    func testConfidenceLikelyForSkippedBranches() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.enum("FixtureEnum312")) {
                self.assertNotUnconstructedEnumCase(.enumelement("constructed"))
                self.assertUnconstructedEnumCase(.enumelement("constructedOnlyOnWindows"))
                self.assertConfidence(.enumelement("constructedOnlyOnWindows"), .likely)
                // Used-but-not-compared control: named in the branch this build compiled, so it is
                // used and not reported.
                self.assertNotUnconstructedEnumCase(.enumelement("comparedInTakenBranch"))
                self.assertUnconstructedEnumCase(.enumelement("matchedOnly"))
                self.assertConfidence(.enumelement("matchedOnly"), .certain)
                // A bare local named like the case is not a use, nor is a `for case` pattern.
                self.assertUnconstructedEnumCase(.enumelement("idle"))
                self.assertConfidence(.enumelement("idle"), .certain)
                self.assertUnconstructedEnumCase(.enumelement("windowsLoopOnly"))
                self.assertConfidence(.enumelement("windowsLoopOnly"), .certain)
            }
            assertReferenced(.enum("FixtureEnum312Other")) {
                // The skipped branch constructs `FixtureEnum312.constructedOnlyOnWindows`, spelled through its
                // type, so it is not a use of this other enum's case of the same name.
                self.assertUnconstructedEnumCase(.enumelement("constructedOnlyOnWindows"))
                self.assertConfidence(.enumelement("constructedOnlyOnWindows"), .certain)
            }
            assertNotReferenced(.typealias("FixtureTypealias312"))
            assertConfidence(.typealias("FixtureTypealias312"), .likely)
            assertNotReferenced(.typealias("FixtureTypealiasUnnamed312"))
            assertConfidence(.typealias("FixtureTypealiasUnnamed312"), .certain)
            assertReferenced(.class("FixtureClass312Pattern")) {
                self.assertNotReferenced(.varStatic("patternWindowsValue"))
                self.assertConfidence(.varStatic("patternWindowsValue"), .likely)
                self.assertNotReferenced(.varStatic("neverMatched"))
                self.assertConfidence(.varStatic("neverMatched"), .certain)
            }
            assertNotReferenced(.struct("FixtureWindowsType312"))
            assertConfidence(.struct("FixtureWindowsType312"), .likely)
            assertReferenced(.enum("FixtureNamespace312")) {
                self.assertNotReferenced(.struct("FixtureTakenType312"))
                self.assertConfidence(.struct("FixtureTakenType312"), .certain)
            }
            assertReferenced(.class("FixtureGeneric312")) {
                self.assertNotReferenced(.functionMethodInstance("windowsGeneric()"))
                self.assertConfidence(.functionMethodInstance("windowsGeneric()"), .likely)
                self.assertReferenced(.functionMethodInstance("takenGeneric()"))
            }
            assertReferenced(.class("FixtureKeyPath312")) {
                self.assertNotReferenced(.varInstance("windowsKeyPathValue"))
                self.assertConfidence(.varInstance("windowsKeyPathValue"), .likely)
                self.assertReferenced(.varInstance("takenKeyPathValue"))
                self.assertNotReferenced(.varInstance("neverKeyPath"))
                self.assertConfidence(.varInstance("neverKeyPath"), .certain)
            }
            assertReferenced(.class("FixtureClass312Taken")) {
                // The taken clause only calls a parameter, which the analysis drops, but the index still
                // shows the clause was compiled, so `handler()` is not named in a skipped branch.
                self.assertNotReferenced(.functionMethodInstance("handler()"))
                self.assertConfidence(.functionMethodInstance("handler()"), .certain)
            }
            assertReferenced(.class("FixtureClass312")) {
                self.assertNotReferenced(.functionMethodInstance("calledOnlyOnWindows()"))
                self.assertConfidence(.functionMethodInstance("calledOnlyOnWindows()"), .likely)
                self.assertReferenced(.functionMethodInstance("calledInTakenBranch()"))
                self.assertNotReferenced(.functionMethodInstance("neverNamed()"))
                self.assertConfidence(.functionMethodInstance("neverNamed()"), .certain)
                self.assertNotReferenced(.functionMethodInstance("WinSDK()"))
                self.assertConfidence(.functionMethodInstance("WinSDK()"), .certain)
                // Declaring a name in a skipped branch is not using it.
                self.assertNotReferenced(.functionMethodInstance("redeclaredOnlyOnWindows()"))
                self.assertConfidence(.functionMethodInstance("redeclaredOnlyOnWindows()"), .certain)
                self.assertNotReferenced(.varInstance("overriddenLabel"))
                self.assertConfidence(.varInstance("overriddenLabel"), .certain)
                // A bare identifier is not a use of a member.
                self.assertNotReferenced(.varInstance("shadowedByLocal"))
                self.assertConfidence(.varInstance("shadowedByLocal"), .certain)
            }
        }
    }

    /// A skipped clause makes likely only the declarations its spelling can name: a call by its argument labels,
    /// a member reached through a type by that type.
    func testConfidenceSkippedBranchNamesOnlyDeclarationsItCanBe() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureLabels5")) {
                // Argument labels.
                self.assertNotReferenced(.functionMethodInstance("show(title:)"))
                self.assertConfidence(.functionMethodInstance("show(title:)"), .likely)
                self.assertNotReferenced(.functionMethodInstance("show(message:)"))
                self.assertConfidence(.functionMethodInstance("show(message:)"), .certain)
                // Labels that are some of the declared ones, in order: `animated` has a default.
                self.assertConfidence(.functionMethodInstance("show(title:animated:)"), .likely)
                // An unlabeled argument can only be passed to an unlabeled parameter.
                self.assertConfidence(.functionMethodInstance("show(_:)"), .likely)
                // A chain follows the declaration its labels name, and not the one they do not.
                self.assertConfidence(.functionMethodInstance("titleHelper()"), .likely)
                self.assertConfidence(.functionMethodInstance("messageHelper()"), .certain)
                // A trailing closure fills a parameter the labels do not spell.
                self.assertConfidence(.functionMethodInstance("run(completion:)"), .likely)
                // A bare reference spells no labels, so any declaration of the name may be meant.
                self.assertConfidence(.functionMethodInstance("pick(by:)"), .likely)
                self.assertConfidence(.functionMethodInstance("pick(of:)"), .likely)
                // `lookup(for:)` is named, `lookup(of:)` is not.
                self.assertConfidence(.functionMethodInstance("lookup(for:)"), .likely)
                self.assertConfidence(.functionMethodInstance("lookup(of:)"), .certain)
                // Used-but-not-compared control: used in the clause this build compiled, so not reported,
                // whatever labels the skipped clause spells.
                self.assertReferenced(.functionMethodInstance("taken(title:)"))
                self.assertReferenced(.functionMethodInstance("calledOnlyHere(title:)"))
                // Labels no declaration has.
                self.assertNotReferenced(.functionMethodInstance("neverNamed(title:)"))
                self.assertConfidence(.functionMethodInstance("neverNamed(title:)"), .certain)
            }
            assertNotReferenced(.functionFree("freeShow5(title:)"))
            assertConfidence(.functionFree("freeShow5(title:)"), .likely)
            assertNotReferenced(.functionFree("freeShow5(message:)"))
            assertConfidence(.functionFree("freeShow5(message:)"), .certain)
            assertReferenced(.class("FixtureInit5")) {
                self.assertReferenced(.functionConstructor("init(label:)"))
                // `String.init(data:encoding:)` is not an initializer of this class; `FixtureInit5.init(other:)` is.
                self.assertConfidence(.functionConstructor("init(other:)"), .likely)
                self.assertConfidence(.functionConstructor("init(unrelated:)"), .certain)
            }
        }
    }

    func testConfidenceSkippedBranchConstructorsAndEnumCasesNarrowByType() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureWidget6")) {
                // `FixtureWidget6(size: 1)` constructs `FixtureWidget6` with those labels, and no other initializer.
                self.assertNotReferenced(.functionConstructor("init(size:)"))
                self.assertConfidence(.functionConstructor("init(size:)"), .likely)
                self.assertNotReferenced(.functionConstructor("init(name:)"))
                self.assertConfidence(.functionConstructor("init(name:)"), .certain)
                // A chain follows the initializer the labels name, and not the one they do not.
                self.assertConfidence(.functionMethodStatic("sizeHelper6()"), .likely)
                self.assertConfidence(.functionMethodStatic("nameHelper6()"), .certain)
                // Used-but-not-compared control: called in the clause this build compiled.
                self.assertReferenced(.functionConstructor("init(count:)"))
                self.assertConfidence(.functionConstructor("init(never:)"), .certain)
            }
            // A trailing closure fills `body`.
            assertReferenced(.struct("FixtureClosureWidget6")) {
                self.assertConfidence(.functionConstructor("init(body:)"), .likely)
            }
            // `T(tag: 1)` in a skipped clause of a generic function constructs whatever `T` is.
            assertReferenced(.struct("FixtureGenericTarget6")) {
                self.assertNotReferenced(.functionConstructor("init(tag:)"))
                self.assertConfidence(.functionConstructor("init(tag:)"), .likely)
            }
            // Another type's initializer with the same labels is not named.
            assertReferenced(.struct("FixtureGadget6")) {
                self.assertNotReferenced(.functionConstructor("init(size:)"))
                self.assertConfidence(.functionConstructor("init(size:)"), .certain)
            }
            // `FixtureEnumA6.ready` is `FixtureEnumA6`'s case; `.go` names no type, so any `go` may be meant.
            assertReferenced(.enum("FixtureEnumA6")) {
                self.assertUnconstructedEnumCase(.enumelement("ready"))
                self.assertConfidence(.enumelement("ready"), .likely)
                self.assertConfidence(.enumelement("go"), .likely)
                // Matching a case in a pattern is not constructing it.
                self.assertConfidence(.enumelement("patternOnly"), .certain)
            }
            assertReferenced(.enum("FixtureEnumB6")) {
                self.assertUnconstructedEnumCase(.enumelement("ready"))
                self.assertConfidence(.enumelement("ready"), .certain)
                self.assertConfidence(.enumelement("go"), .likely)
                self.assertConfidence(.enumelement("patternOnly"), .certain)
            }
            // An initializer in an extension of an unscanned type is named only by a construction of that type.
            assertReferenced(.extensionStruct("URL")) {
                self.assertConfidence(.functionConstructor("init(fixtureHex6:)"), .certain)
                self.assertConfidence(.functionConstructor("init(fixtureHex6:alpha:)"), .certain)
                self.assertConfidence(.functionConstructor("init(fixtureOtherTint6:)"), .certain)
                self.assertConfidence(.functionConstructor("init(_:)"), .certain)
                self.assertConfidence(.functionConstructor("init(fixtureTint6:)"), .likely)
            }
            assertReferenced(.extensionStruct("Double")) {
                self.assertConfidence(.functionConstructor("init(_:)"), .likely)
            }
        }
    }

    func testConfidenceSkippedBranchReceiverTypeNarrowsMembers() throws {
        try analyze(retainPublic: true) {
            // Spelled through the type: `FixtureStoreA5.shared` is `FixtureStoreA5`'s.
            assertReferenced(.class("FixtureStoreA5")) {
                self.assertNotReferenced(.varStatic("shared"))
                self.assertConfidence(.varStatic("shared"), .likely)
                self.assertConfidence(.functionMethodStatic("make5()"), .likely)
            }
            assertReferenced(.class("FixtureStoreB5")) {
                self.assertNotReferenced(.varStatic("shared"))
                self.assertConfidence(.varStatic("shared"), .certain)
                self.assertConfidence(.functionMethodStatic("make5()"), .certain)
            }
            // A type alias names the type it stands for.
            assertReferenced(.class("FixtureStoreC5")) {
                self.assertConfidence(.varStatic("shared"), .likely)
            }
            assertReferenced(.class("FixtureNeverNamed5")) {
                self.assertConfidence(.varStatic("shared"), .certain)
            }
            // A subclass reaches what its superclass declares, and an override what it overrides.
            assertReferenced(.class("FixtureBase5")) {
                self.assertConfidence(.functionMethodClass("baseMake5()"), .likely)
            }
            assertReferenced(.class("FixtureOverride5")) {
                self.assertConfidence(.functionMethodClass("baseMake5()"), .likely)
            }
            // A conforming type reaches the protocol extension's members: no type to narrow them to.
            assertReferenced(.extensionProtocol("FixtureProtocol5")) {
                self.assertConfidence(.functionMethodStatic("protocolMake5()"), .likely)
            }
            // A use that names no type can be of any type's member, as can a generic parameter's.
            assertReferenced(.class("FixtureUnqualifiedA5")) {
                self.assertConfidence(.varInstance("tick5"), .likely)
            }
            assertReferenced(.class("FixtureUnqualifiedB5")) {
                self.assertConfidence(.varInstance("tick5"), .likely)
            }
            assertReferenced(.class("FixtureGenericA5")) {
                self.assertConfidence(.varStatic("generic5"), .likely)
            }
            assertReferenced(.class("FixtureGenericB5")) {
                self.assertConfidence(.varStatic("generic5"), .likely)
            }
        }
    }

    func testConfidenceLikelyForOperatorsUsedInSkippedBranches() throws {
        try analyze(retainPublic: true) {
            assertNotReferenced(.functionOperatorInfix("<~~>(_:_:)"))
            assertConfidence(.functionOperatorInfix("<~~>(_:_:)"), .likely)
            assertNotReferenced(.functionOperatorPrefix("^^^(_:)"))
            assertConfidence(.functionOperatorPrefix("^^^(_:)"), .likely)
            // Never named: stays certain.
            assertNotReferenced(.functionOperatorInfix("<!!>(_:_:)"))
            assertConfidence(.functionOperatorInfix("<!!>(_:_:)"), .certain)
            // Used in the branch this build compiled: not reported.
            assertReferenced(.functionOperatorInfix("<??>(_:_:)"))
        }
    }

    func testRetainsResultBuilderPartialBlockAndArity() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct225")) {
                self.assertReferenced(.functionMethodStatic("buildPartialBlock(first:)"))
                self.assertReferenced(.functionMethodStatic("buildPartialBlock(accumulated:next:)"))
                self.assertReferenced(.functionMethodStatic("buildBlock(_:_:_:)"))
                self.assertReferenced(.functionMethodStatic("buildExpression(_:scale:)"))
                self.assertNotReferenced(.functionMethodStatic("buildSomethingElse()"))
            }
            assertReferenced(.struct("FixtureStruct225NotABuilder")) {
                self.assertNotReferenced(.functionMethodStatic("buildBlock(_:)"))
            }
        }
    }

    func testRetainsPropertyWrapperInitializers() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("Fixture225Wrapper")) {
                self.assertReferenced(.functionConstructor("init(wrappedValue:)"))
                self.assertReferenced(.functionConstructor("init(wrappedValue:clampedTo:)"))
                self.assertReferenced(.functionConstructor("init(projectedValue:)"))
                self.assertNotReferenced(.functionConstructor("init(other:)"))
            }
        }
    }

    func testCodableSynthesizedEncodeReads() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct226")) {
                self.assertNotAssignOnlyProperty(.varInstance("encoded"))
                self.assertNotAssignOnlyProperty(.varInstance("nested"))
            }
            assertReferenced(.struct("FixtureStruct226Nested")) {
                self.assertNotAssignOnlyProperty(.varInstance("nestedValue"))
            }
            assertReferenced(.struct("FixtureStruct226Codable")) {
                self.assertNotAssignOnlyProperty(.varInstance("codableEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Generic")) {
                self.assertNotAssignOnlyProperty(.varInstance("genericEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Existential")) {
                self.assertNotAssignOnlyProperty(.varInstance("existentialEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Unencoded")) {
                self.assertAssignOnlyProperty(.varInstance("neverEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Passed")) {
                self.assertAssignOnlyProperty(.varInstance("passedButNotEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Appended")) {
                self.assertAssignOnlyProperty(.varInstance("appendedButNotEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Metatype")) {
                self.assertAssignOnlyProperty(.varInstance("metatypeNotEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Overload")) {
                self.assertNotAssignOnlyProperty(.varInstance("overloadEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Held")) {
                self.assertNotAssignOnlyProperty(.varInstance("heldEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Computed")) {
                self.assertNotAssignOnlyProperty(.varInstance("computedEncoded"))
                self.assertNotReferenced(.varInstance("computedNotEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226ObservedChild")) {
                self.assertNotAssignOnlyProperty(.varInstance("observedChildEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Custom")) {
                self.assertAssignOnlyProperty(.varInstance("notEncodedByCustom"))
            }
        }
    }

    func testCodableSynthesizedEncodeEdgeCases() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct227Keyed")) {
                self.assertNotAssignOnlyProperty(.varInstance("listed"))
                self.assertAssignOnlyProperty(.varInstance("omitted"))
            }
            assertReferenced(.class("FixtureClass227Keyed")) {
                self.assertNotAssignOnlyProperty(.varInstance("listed"))
                self.assertAssignOnlyProperty(.varInstance("omitted"))
            }
            assertReferenced(.struct("FixtureStruct227Plain")) {
                self.assertNotAssignOnlyProperty(.varInstance("plain"))
            }
            assertReferenced(.class("FixtureClass227Plain")) {
                self.assertNotAssignOnlyProperty(.varInstance("plain"))
            }
            assertReferenced(.class("FixtureClass227PrivateSub")) {
                self.assertNotAssignOnlyProperty(.varInstance("synthesized"))
            }
            assertReferenced(.class("FixtureClass227InternalSub")) {
                self.assertAssignOnlyProperty(.varInstance("inherited"))
            }
            assertReferenced(.struct("FixtureStruct227Witness")) {
                self.assertAssignOnlyProperty(.varInstance("viaExtension"))
            }
            assertReferenced(.class("FixtureClass227Witness")) {
                self.assertAssignOnlyProperty(.varInstance("viaExtension"))
            }
            assertReferenced(.struct("FixtureStruct227PlainConforming")) {
                self.assertNotAssignOnlyProperty(.varInstance("conformed"))
            }
            assertReferenced(.class("FixtureClass227FilePrivateSub")) {
                self.assertAssignOnlyProperty(.varInstance("inheritedInFile"))
            }
            assertReferenced(.struct("FixtureStruct227Unmarked")) {
                self.assertNotAssignOnlyProperty(.varInstance("unmarked"))
            }
            assertReferenced(.struct("FixtureStruct227Marked")) {
                self.assertAssignOnlyProperty(.varInstance("marked"))
            }
            assertReferenced(.class("FixtureClass227Concrete")) {
                self.assertAssignOnlyProperty(.varInstance("throughMid"))
            }
            assertReferenced(.struct("FixtureStruct227ClassConstrained")) {
                self.assertNotAssignOnlyProperty(.varInstance("classConstrained"))
            }
            assertReferenced(.struct("FixtureStruct227Static")) {
                self.assertNotAssignOnlyProperty(.varInstance("staticOverload"))
            }
            assertReferenced(.class("FixtureClass227Read")) {
                self.assertNotAssignOnlyProperty(.varInstance("readNormally"))
            }
        }
    }

    func testCodableSynthesizedEncodeReadsThroughStoredProperty() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass226Stored")) {
                self.assertNotAssignOnlyProperty(.varInstance("classStoredEncoded"))
            }
            assertReferenced(.struct("FixtureStruct226Stored")) {
                self.assertNotAssignOnlyProperty(.varInstance("structStoredEncoded"))
            }
            assertReferenced(.class("FixtureClass226Unencoded")) {
                self.assertAssignOnlyProperty(.varInstance("classNeverEncoded"))
            }
            assertReferenced(.class("FixtureClass226Base")) {
                self.assertNotAssignOnlyProperty(.varInstance("baseEncoded"))
            }
            assertReferenced(.class("FixtureClass226Sub")) {
                self.assertAssignOnlyProperty(.varInstance("subNotEncoded"))
            }
            assertReferenced(.class("FixtureClass226InheritedEncoder")) {
                self.assertAssignOnlyProperty(.varInstance("inheritedNotEncoded"))
            }
            assertReferenced(.class("FixtureClass226Read")) {
                self.assertNotAssignOnlyProperty(.varInstance("classReadNormally"))
            }
        }
    }

    func testCodableSynthesizedDecodeReads() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct312")) {
                self.assertNotAssignOnlyProperty(.varInstance("decoded"))
                self.assertNotAssignOnlyProperty(.varInstance("nested"))
                self.assertNotAssignOnlyProperty(.varInstance("withDefault"))
                self.assertNotReferenced(.varInstance("fixed"))
            }
            assertReferenced(.struct("FixtureStruct312Nested")) {
                self.assertNotAssignOnlyProperty(.varInstance("nestedValue"))
            }
            assertReferenced(.struct("FixtureStruct312Codable")) {
                self.assertNotAssignOnlyProperty(.varInstance("codableDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Generic")) {
                self.assertNotAssignOnlyProperty(.varInstance("genericDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Extension")) {
                self.assertNotAssignOnlyProperty(.varInstance("extensionDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Keyed")) {
                self.assertNotAssignOnlyProperty(.varInstance("kept"))
                self.assertAssignOnlyProperty(.varInstance("skipped"))
            }
            assertReferenced(.struct("FixtureStruct312Undecoded")) {
                self.assertAssignOnlyProperty(.varInstance("neverDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Optional")) {
                self.assertAssignOnlyProperty(.varInstance("optionalDecoded"))
                self.assertAssignOnlyProperty(.varInstance("spelledOutOptional"))
                self.assertAssignOnlyProperty(.varInstance("implicitlyUnwrapped"))
            }
            assertReferenced(.struct("FixtureStruct312Passed")) {
                self.assertAssignOnlyProperty(.varInstance("passedButNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Printed")) {
                self.assertAssignOnlyProperty(.varInstance("printedButNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Metadata")) {
                self.assertAssignOnlyProperty(.varInstance("metadataNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Placeholder")) {
                self.assertNotAssignOnlyProperty(.varInstance("placeholderDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Where")) {
                self.assertNotAssignOnlyProperty(.varInstance("whereDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Initializer")) {
                self.assertNotAssignOnlyProperty(.varInstance("initializerDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Variadic")) {
                self.assertNotAssignOnlyProperty(.varInstance("variadicDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312VariadicOther")) {
                self.assertNotAssignOnlyProperty(.varInstance("variadicOtherDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Dependent")) {
                self.assertAssignOnlyProperty(.varInstance("dependentNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Boxed")) {
                self.assertAssignOnlyProperty(.varInstance("boxedNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312ValueOnly")) {
                self.assertAssignOnlyProperty(.varInstance("valueNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Composed")) {
                self.assertNotAssignOnlyProperty(.varInstance("composedDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Aliased")) {
                self.assertAssignOnlyProperty(.varInstance("aliasedNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Key")) {
                self.assertAssignOnlyProperty(.varInstance("keyNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Lazy")) {
                self.assertNotAssignOnlyProperty(.varInstance("lazyAnchor"))
            }
            assertReferenced(.struct("FixtureStruct312Holder")) {
                self.assertAssignOnlyProperty(.varInstance("child"))
            }
            assertReferenced(.struct("FixtureStruct312Child")) {
                self.assertNotAssignOnlyProperty(.varInstance("childRequired"))
            }
            assertReferenced(.struct("FixtureStruct312Page")) {
                self.assertNotAssignOnlyProperty(.varInstance("items"))
                self.assertNotAssignOnlyProperty(.varInstance("total"))
            }
            assertReferenced(.struct("FixtureStruct312Item")) {
                self.assertNotAssignOnlyProperty(.varInstance("itemDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Phantom")) {
                self.assertNotAssignOnlyProperty(.varInstance("count"))
            }
            assertReferenced(.struct("FixtureStruct312Tag")) {
                self.assertAssignOnlyProperty(.varInstance("tagNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Nested2")) {
                self.assertAssignOnlyProperty(.varInstance("nested2NotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Entry")) {
                self.assertNotAssignOnlyProperty(.varInstance("entryDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Overload")) {
                self.assertNotAssignOnlyProperty(.varInstance("overloadDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312AliasInit")) {
                self.assertAssignOnlyProperty(.varInstance("aliasInitNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Fake")) {
                self.assertAssignOnlyProperty(.varInstance("fakeNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312SharedKeys")) {
                self.assertNotAssignOnlyProperty(.varInstance("sharedKept"))
                self.assertAssignOnlyProperty(.varInstance("sharedSkipped"))
            }
            assertReferenced(.struct("FixtureStruct312ChainInit")) {
                self.assertAssignOnlyProperty(.varInstance("chainInitNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312NumberOverload")) {
                self.assertNotAssignOnlyProperty(.varInstance("numberOverloadDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312ChainKeys")) {
                self.assertNotAssignOnlyProperty(.varInstance("sharedKept"))
                self.assertAssignOnlyProperty(.varInstance("sharedSkipped"))
            }
            assertReferenced(.struct("FixtureStruct312Unkeyed")) {
                self.assertNotAssignOnlyProperty(.varInstance("unkeyedDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Single")) {
                self.assertNotAssignOnlyProperty(.varInstance("singleDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Protocol")) {
                self.assertNotAssignOnlyProperty(.varInstance("protocolDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Shadowing")) {
                self.assertNotAssignOnlyProperty(.varInstance("shadowingDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Qualified")) {
                self.assertAssignOnlyProperty(.varInstance("qualifiedNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312QualifiedPlain")) {
                self.assertNotAssignOnlyProperty(.varInstance("qualifiedPlainDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Concrete")) {
                self.assertAssignOnlyProperty(.varInstance("concreteNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Wrapped")) {
                self.assertNotAssignOnlyProperty(.varInstance("wrappedDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312OptionalModel")) {
                self.assertNotAssignOnlyProperty(.varInstance("optionalModelDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312ArrayModel")) {
                self.assertNotAssignOnlyProperty(.varInstance("arrayModelDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312OptionalItem")) {
                self.assertNotAssignOnlyProperty(.varInstance("optionalItemDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312TableItem")) {
                self.assertNotAssignOnlyProperty(.varInstance("tableItemDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312DictModel")) {
                self.assertNotAssignOnlyProperty(.varInstance("dictModelDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Computed")) {
                self.assertNotAssignOnlyProperty(.varInstance("computedAnchor"))
                self.assertNotReferenced(.varInstance("computedConstant"))
            }
            assertReferenced(.enum("FixtureQualifiedHolder312")) {
                self.assertReferenced(.struct("Model")) {
                    self.assertNotAssignOnlyProperty(.varInstance("qualifiedModelDecoded"))
                }
            }
            assertReferenced(.struct("FixtureStruct312Aliased1")) {
                self.assertNotAssignOnlyProperty(.varInstance("aliased1Decoded"))
            }
            assertReferenced(.struct("FixtureStruct312Aliased2")) {
                self.assertNotAssignOnlyProperty(.varInstance("aliased2Decoded"))
            }
            assertReferenced(.struct("FixtureStruct312AliasedCustom")) {
                self.assertAssignOnlyProperty(.varInstance("aliasedCustomNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312QualifiedConcrete")) {
                self.assertAssignOnlyProperty(.varInstance("qualifiedConcreteNotDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312ObservedChild")) {
                self.assertNotAssignOnlyProperty(.varInstance("observedChildDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312AliasPageItem")) {
                self.assertNotAssignOnlyProperty(.varInstance("aliasPageItemDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312ExternalKeys")) {
                self.assertNotAssignOnlyProperty(.varInstance("externalKept"))
            }
            assertReferenced(.struct("FixtureStruct312NestedItem")) {
                self.assertNotAssignOnlyProperty(.varInstance("nestedItemDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312LabeledA")) {
                self.assertNotAssignOnlyProperty(.varInstance("labeledADecoded"))
            }
            assertReferenced(.struct("FixtureStruct312LabeledB")) {
                self.assertNotAssignOnlyProperty(.varInstance("labeledBDecoded"))
            }
            assertReferenced(.struct("FixtureStruct312Custom")) {
                self.assertAssignOnlyProperty(.varInstance("notDecodedByCustom"))
            }
        }
    }

    func testCodableSynthesizedDecodeTopLevel() throws {
        let main = FixturesProjectPath.appending("Sources/RetentionFixtures/main.swift")

        try analyze(retainPublic: true, additionalFilesToIndex: [main]) {
            assertReferenced(.struct("FixtureStruct314")) {
                self.assertNotAssignOnlyProperty(.varInstance("topLevelDecoded"))
            }
            assertReferenced(.struct("FixtureStruct314Undecoded")) {
                self.assertAssignOnlyProperty(.varInstance("topLevelNotDecoded"))
            }
        }

        // Without the top-level file nothing decodes FixtureStruct314.
        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct314")) {
                self.assertAssignOnlyProperty(.varInstance("topLevelDecoded"))
            }
        }
    }

    func testCodableSynthesizedDecodeExternalProtocol() throws {
        // CustomStringConvertible doesn't actually inherit Decodable, we're just using it because we don't have an
        // external module in which to declare our own type.
        try analyze(retainPublic: true, externalCodableProtocols: ["CustomStringConvertible"]) {
            assertReferenced(.struct("FixtureStruct313")) {
                self.assertNotAssignOnlyProperty(.varInstance("externallyDecoded"))
            }
        }

        try analyze(retainPublic: true) {
            assertReferenced(.struct("FixtureStruct313")) {
                self.assertAssignOnlyProperty(.varInstance("externallyDecoded"))
            }
        }
    }

    /// The macro's generated extension must not keep its own class alive.
    func testReportsUnusedObservableClass() throws {
        try analyze(retainPublic: true) {
            assertNotReferenced(.class("FixtureClass227"))
            assertReferenced(.class("FixtureClass227Used")) {
                self.assertReferenced(.varInstance("name"))
            }
        }
    }

    func testUnconstructedEnumCases() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.enum("FixtureEnum229")) {
                self.assertUnconstructedEnumCase(.enumelement("matchedOnly"))
                self.assertUnconstructedEnumCase(.enumelement("payloadMatchedOnly(_:)"))
                self.assertNotUnconstructedEnumCase(.enumelement("constructed"))
                self.assertNotUnconstructedEnumCase(.enumelement("comparedOnly"))
            }
            assertReferenced(.enum("FixtureEnum229Other")) {
                self.assertNotUnconstructedEnumCase(.enumelement("matchedOnly"))
            }
            assertReferenced(.enum("FixtureEnum229Raw")) {
                self.assertNotUnconstructedEnumCase(.enumelement("matchedOnly"))
            }
            assertReferenced(.enum("FixtureEnum229Iterable")) {
                self.assertNotUnconstructedEnumCase(.enumelement("matchedOnly"))
            }
            assertReferenced(.enum("FixtureEnum229Public")) {
                self.assertNotUnconstructedEnumCase(.enumelement("matchedOnly"))
            }
        }
    }

    func testReportsUnusedSubscriptParameter() throws {
        try analyze(retainPublic: true) {
            assertReferenced(.class("FixtureClass233")) {
                self.assertReferenced(.functionSubscript("subscript(_:_:)")) {
                    self.assertNotReferenced(.varParameter("column"))
                    self.assertUsedParameter("row")
                }
                self.assertReferenced(.varInstance("transform")) {
                    self.assertNotReferenced(.varParameter("unused"))
                    self.assertUsedParameter("used")
                }
            }
            assertReferenced(.struct("FixtureStruct233Collection")) {
                self.assertReferenced(.functionSubscript("subscript(_:)")) {
                    self.assertReferenced(.varParameter("position"))
                }
            }
        }
    }
}

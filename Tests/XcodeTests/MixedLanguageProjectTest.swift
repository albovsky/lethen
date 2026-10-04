import Configuration
@testable import PeripheryKit
@testable import TestShared
import XCTest

/// Swift declarations used only from Objective-C. MixedLanguageProject's `ObjCCaller.m` imports the
/// generated `MixedLanguageProject-Swift.h` and calls into `ObjCExposed.swift`; `ObjCCaller.h` names one
/// Swift class in a function prototype.
final class MixedLanguageProjectTest: XcodeSourceGraphTestCase {
    private static func makeConfiguration() -> Configuration {
        let configuration = Configuration()
        configuration.schemes = ["MixedLanguageProject"]
        return configuration
    }

    override static func setUp() {
        super.setUp()

        let configuration = makeConfiguration()

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

    /// `@objc(name)` renames the declaration for Objective-C, and the string spells that name.
    func testObjectiveCNamesSpelledInLiteralsAreLikely() {
        assertReferenced(.class("CalledFromObjC")) {
            self.assertNotReferenced(.functionMethodInstance("renamedSelectorInSwift()"))
            self.assertConfidence(.functionMethodInstance("renamedSelectorInSwift()"), .likely)
        }
        assertNotReferenced(.class("RenamedStringClass"))
        assertConfidence(.class("RenamedStringClass"), .likely)
    }

    /// A property's setter selector and an initializer's Objective-C selector are lookups by name too.
    func testSetterAndInitializerSelectorsSpelledInLiteralsAreLikely() {
        assertReferenced(.class("CalledFromObjC")) {
            self.assertNotReferenced(.varInstance("writtenBySetterSelector"))
            self.assertConfidence(.varInstance("writtenBySetterSelector"), .likely)
            self.assertNotReferenced(.functionConstructor("init(objcName:)"))
            self.assertConfidence(.functionConstructor("init(objcName:)"), .likely)
        }
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

    // MARK: - Targets the scheme does not build

    private static let unscannedPlace = "UnscannedTool/UnscannedMain.swift:%d, a file of target UnscannedTool, which the scanned schemes do not build"

    private func confidenceReason(ofDeclarationNamed name: String) -> String? {
        Self.results.first { $0.declaration.name == name }?.confidenceReason
    }

    func testPlanNamesTheUnscannedToolAndTheFileItSharesWithAScannedTarget() throws {
        let targets = try XCTUnwrap(Self.plan?.unscannedTargets)

        XCTAssertEqual(targets.map(\.name), ["UnscannedTool"])
        // The target sets PRODUCT_MODULE_NAME, which is what its units would carry.
        XCTAssertEqual(try XCTUnwrap(Self.plan?.unscannedTargets.first?.name), "UnscannedTool")
        let target = try XCTUnwrap(targets.first)
        XCTAssertEqual(target.sharedSourceFiles.compactMap { $0.lastComponent?.string }, ["SharedBetweenTargets.swift"])
        XCTAssertEqual(target.swiftSourceFiles.compactMap { $0.lastComponent?.string }.sorted(), ["SharedBetweenTargets.swift", "UnscannedMain.swift"])
    }

    /// Public API used only by a target no scheme builds is likely, not certainly, unused.
    func testPublicDeclarationsNamedByTheUnscannedTargetAreLikely() {
        assertReferenced(.class("FrameworkSwiftClass")) {
            self.assertNotReferenced(.functionMethodInstance("onlyCalledFromUnscannedTarget()"))
            self.assertConfidence(.functionMethodInstance("onlyCalledFromUnscannedTarget()"), .likely)
        }
        assertReferenced(.class("PublicStore")) {
            self.assertNotReferenced(.varInstance("memberReadFromUnscannedTarget"))
            self.assertConfidence(.varInstance("memberReadFromUnscannedTarget"), .likely)
            // `PublicStore(label:)` is a call of an initializer, `store[0]` of a subscript.
            self.assertNotReferenced(.functionConstructor("init(label:)"))
            self.assertConfidence(.functionConstructor("init(label:)"), .likely)
            self.assertNotReferenced(.functionSubscript("subscript(_:)"))
            self.assertConfidence(.functionSubscript("subscript(_:)"), .likely)
        }
        let reason = confidenceReason(ofDeclarationNamed: "onlyCalledFromUnscannedTarget()")
        XCTAssertEqual(reason.map { $0.components(separatedBy: " appears in ").first }, "its name")
        XCTAssertTrue(reason?.hasSuffix(String(format: Self.unscannedPlace, 8)) == true, reason ?? "nil")
        XCTAssertTrue(confidenceReason(ofDeclarationNamed: "memberReadFromUnscannedTarget")?.hasSuffix(String(format: Self.unscannedPlace, 11)) == true)
    }

    /// Constructs the unscanned target uses without spelling the member: an override, `Handler()()`, and a
    /// member reached through a chain of type aliases.
    func testOverridesCallableValuesAndAliasChainsAreLikely() {
        assertReferenced(.class("OverridableBase")) {
            self.assertNotReferenced(.functionMethodInstance("overriddenInUnscannedTarget()"))
            self.assertConfidence(.functionMethodInstance("overriddenInUnscannedTarget()"), .likely)
            // The control: nothing overrides it.
            self.assertNotReferenced(.functionMethodInstance("neverOverridden()"))
            self.assertConfidence(.functionMethodInstance("neverOverridden()"), .certain)
        }
        assertReferenced(.struct("CallableHandler")) {
            self.assertNotReferenced(.functionMethodInstance("callAsFunction()", line: 69))
            self.assertConfidence(.functionMethodInstance("callAsFunction()", line: 69), .likely)
        }
        // The control: the tool never names `UncalledHandler`, so it runs no `callAsFunction` of it.
        assertReferenced(.struct("UncalledHandler")) {
            self.assertNotReferenced(.functionMethodInstance("callAsFunction()", line: 76))
            self.assertConfidence(.functionMethodInstance("callAsFunction()", line: 76), .certain)
        }
        assertReferenced(.class("AliasedOriginal")) {
            self.assertNotReferenced(.varStatic("sharedThroughAliasChain"))
            self.assertConfidence(.varStatic("sharedThroughAliasChain"), .likely)
        }
    }

    /// An internal declaration of a file the target compiles has its own copy there, which the target's
    /// other files use; `SharedEntry` is named nowhere and reached only through `SharedWidget`.
    func testDeclarationsOfASharedFileAreLikelyDirectlyAndThroughTheChain() {
        assertNotReferenced(.struct("SharedWidget"))
        assertConfidence(.struct("SharedWidget"), .likely)
        XCTAssertTrue(confidenceReason(ofDeclarationNamed: "SharedWidget")?.hasSuffix(String(format: Self.unscannedPlace, 14)) == true)

        assertNotReferenced(.struct("SharedEntry"))
        assertConfidence(.struct("SharedEntry"), .likely)
        XCTAssertEqual(
            // `SharedWidget()` names both the type and its initializer; either carries the name on.
            confidenceReason(ofDeclarationNamed: "SharedEntry")?.hasPrefix("it is used by SharedWidget") == true
                && confidenceReason(ofDeclarationNamed: "SharedEntry")?.contains(", whose name appears in ") == true,
            true,
            confidenceReason(ofDeclarationNamed: "SharedEntry") ?? "nil"
        )
        XCTAssertTrue(confidenceReason(ofDeclarationNamed: "SharedEntry")?.hasSuffix(String(format: Self.unscannedPlace, 14)) == true)
    }

    /// Retained controls: nothing names these in the unscanned target in a way that can use them.
    func testDeclarationsTheUnscannedTargetCannotUseStayCertain() {
        assertNotReferenced(.struct("SharedUnused"))
        assertConfidence(.struct("SharedUnused"), .certain)
        // The name is only a local variable there.
        assertNotReferenced(.functionFree("notCalledFromUnscannedTarget()"))
        assertConfidence(.functionFree("notCalledFromUnscannedTarget()"), .certain)
        // Internal and not in a file the target compiles; the target's own function of that name is another one.
        assertNotReferenced(.functionFree("internalNamedFromUnscannedTarget()"))
        assertConfidence(.functionFree("internalNamedFromUnscannedTarget()"), .certain)
        // The tool names `PublicStore`, which says nothing about a member it never names.
        assertReferenced(.class("PublicStore")) {
            self.assertNotReferenced(.functionMethodInstance("neverNamed()"))
            self.assertConfidence(.functionMethodInstance("neverNamed()"), .certain)
        }
        // Private in the shared file; the tool's `SharedPrivate()` is its own type of that name.
        assertNotReferenced(.struct("SharedPrivate", line: 17))
        assertConfidence(.struct("SharedPrivate", line: 17), .certain)
        // Spelled as a member call on the tool's own type; `UnnamedStore` itself is never named.
        assertReferenced(.class("UnnamedStore")) {
            self.assertNotReferenced(.functionMethodInstance("memberNamedWithoutItsType()"))
            self.assertConfidence(.functionMethodInstance("memberNamedWithoutItsType()"), .certain)
        }
        // Matched in a pattern, which does not construct a case.
        assertReferenced(.enum("PublicMode")) {
            self.assertNotReferenced(.enumelement("matchedOnly"))
            self.assertConfidence(.enumelement("matchedOnly"), .certain)
        }
    }

    /// The control: used by the scanned tool, so it is referenced, not compared, even though the unscanned
    /// target names it too.
    func testDeclarationUsedByTheScannedTargetIsReferencedNotCompared() {
        assertReferenced(.class("PublicStore")) {
            self.assertReferenced(.functionMethodInstance("usedFromScannedTarget()"))
        }
        assertReferenced(.enum("PublicMode")) {
            self.assertReferenced(.enumelement("constructed"))
        }
    }

    // MARK: - Unused `@import`

    /// An `@import` of a module whose Swift code the scan indexed (`MixedFramework`) is unused when the
    /// file uses no symbol of it. `@import Foundation` is never checked: the scan indexed no Swift code
    /// of it.
    func testReportsImportsThatUseNothingFromTheModule() {
        file("ImportsNothing.m") {
            self.assertImport("MixedFramework", inFile: "ImportsNothing.m")
            self.assertNotReferenced(.module("MixedFramework", line: 2))
            self.assertReferenced(.module("Foundation"))
        }
    }

    /// Submodule precision: the file uses `MFIsEqual` from `MixedFramework.MFComparison` but nothing
    /// from `MixedFramework.MFLogging`, which is reported by its qualified name.
    func testReportsUnusedSubmoduleImportButKeepsTheUsedOne() {
        file("ImportsUsedFunction.m") {
            self.assertImport("MixedFramework.MFComparison", inFile: "ImportsUsedFunction.m")
            self.assertNotReferenced(.module("MixedFramework.MFLogging"))
            self.assertReferenced(.module("MixedFramework.MFComparison"))
            self.assertReferenced(.module("MixedFramework"))
        }
    }

    func testRetainsImportsWhoseModuleIsUsed() {
        file("ImportsUsedMacro.m") {
            self.assertImport("MixedFramework.MFLogging", inFile: "ImportsUsedMacro.m")
            self.assertReferenced(.module("MixedFramework.MFLogging"))
        }
        // A Swift class of the framework, reached through the generated header's submodule.
        file("ImportsUsedSwiftClass.m") {
            self.assertImport("MixedFramework", inFile: "ImportsUsedSwiftClass.m")
            self.assertReferenced(.module("MixedFramework"))
        }
    }

    /// `FrameworkWidthW100` is a case of an `@objc` enum nested in a class, which the Swift index
    /// records under its Swift USR only, so the use resolves to no Swift declaration; the module in the
    /// clang USR still says the import is needed.
    func testRetainsImportUsedOnlyThroughAnUnresolvableSwiftSymbol() {
        file("ImportsUsedNestedEnum.m") {
            self.assertImport("MixedFramework", inFile: "ImportsUsedNestedEnum.m")
            self.assertReferenced(.module("MixedFramework"))
        }
    }

    /// The only use is in a header the file includes, which is a compile requirement of the file too.
    func testRetainsImportUsedOnlyByAnIncludedHeader() {
        file("ImportsUsedByHeader.m") {
            self.assertImport("MixedFramework.MFComparison", inFile: "ImportsUsedByHeader.m")
            self.assertReferenced(.module("MixedFramework.MFComparison"))
        }
    }

    /// Controls: an ignore command and a conditional import are read and kept.
    func testRetainsIgnoredAndConditionalImports() {
        file("ImportsIgnored.m") {
            self.assertImport("MixedFramework", inFile: "ImportsIgnored.m")
            self.assertImport("MixedFramework.MFComparison", inFile: "ImportsIgnored.m")
            self.assertReferenced(.module("MixedFramework"))
            self.assertReferenced(.module("MixedFramework.MFComparison"))
        }
    }

    /// `@class Name;` names the type without using it, so it is not a use of the module either.
    func testForwardDeclarationIsNotAUseOfTheModule() {
        file("ImportsForwardDeclaration.m") {
            self.assertImport("MixedFramework", inFile: "ImportsForwardDeclaration.m")
            self.assertNotReferenced(.module("MixedFramework"))
        }
    }

    /// `// periphery:ignore:all` ignores the whole file, imports included.
    func testRetainsEveryImportOfAFileWithAFileWideIgnoreCommand() {
        file("ImportsIgnoredAll.m") {
            self.assertImport("MixedFramework", inFile: "ImportsIgnoredAll.m")
            self.assertImport("MixedFramework.MFComparison", inFile: "ImportsIgnoredAll.m")
            self.assertReferenced(.module("MixedFramework"))
            self.assertReferenced(.module("MixedFramework.MFComparison"))
        }
    }

    /// A header excluded from the index is as if absent, so its uses no longer keep the import of the
    /// file that includes it.
    func testExcludedHeaderIsNotEvidenceForAnImport() throws {
        let configuration = Self.makeConfiguration()
        configuration.indexExclude = ["**/ImportsUsedByHeader.h"]
        configuration.buildFilenameMatchers()
        try index(configuration: configuration)
        defer { XCTAssertNoThrow(try index(configuration: Self.makeConfiguration())) }

        file("ImportsUsedByHeader.m") {
            self.assertImport("MixedFramework.MFComparison", inFile: "ImportsUsedByHeader.m")
            self.assertNotReferenced(.module("MixedFramework.MFComparison"))
        }
    }

    func testRetainedModuleIsNotReported() throws {
        let configuration = Self.makeConfiguration()
        configuration.retainUnusedImportedModules = ["MixedFramework"]
        try index(configuration: configuration)
        defer { XCTAssertNoThrow(try index(configuration: Self.makeConfiguration())) }

        file("ImportsNothing.m") {
            self.assertImport("MixedFramework", inFile: "ImportsNothing.m")
            self.assertReferenced(.module("MixedFramework"))
        }
        file("ImportsUsedFunction.m") {
            self.assertReferenced(.module("MixedFramework.MFLogging"))
        }
    }

    func testDisabledAnalysisReportsNoImports() throws {
        let configuration = Self.makeConfiguration()
        configuration.disableUnusedImportAnalysis = true
        try index(configuration: configuration)
        defer { XCTAssertNoThrow(try index(configuration: Self.makeConfiguration())) }

        file("ImportsNothing.m") {
            self.assertReferenced(.module("MixedFramework"))
        }
    }
}

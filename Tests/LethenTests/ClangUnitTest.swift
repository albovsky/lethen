import Configuration
@testable import Indexer
import SystemPackage
@testable import TestShared
import XCTest

/// Clang index units (C and Objective-C files) are kept out of the Swift indexer.
final class ClangUnitTest: FixtureSourceGraphTestCase {
    private var clangSourcePath: FilePath {
        FixturesProjectPath.appending("Sources/ClangUnitSupportFixtures/ClangUnitSupport.c")
    }

    private var objcSourcePath: FilePath {
        FixturesProjectPath.appending("Sources/ClangUnitObjcSupportFixtures/ClangUnitObjcSupport.m")
    }

    func testClangLiteralsAreConfidenceEvidence() throws {
        // SwiftPM in the Swift 6.4 Linux image writes no index units for C targets, so no literal is read.
        let hasClangUnits = try !XCTUnwrap(Self.plan).clangSourceFiles.isEmpty
        #if os(macOS)
            XCTAssertTrue(hasClangUnits)
        #endif

        try analyze(retainPublic: true, additionalFilesToIndex: [clangSourcePath, objcSourcePath]) {
            assertReferenced(.class("FixtureClass240")) {
                // Named only in C and Objective-C string literals, which the index cannot show as a
                // reference to this declaration. No selector or key resolves to a pure-Swift method, so
                // this one stays certain, while a Swift class, which `NSClassFromString` can load, is looked up by the literal.
                self.assertNotReferenced(.functionMethodInstance("namedInClangLiteral()"))
                self.assertConfidence(.functionMethodInstance("namedInClangLiteral()"), .certain)
                // A pure-Swift method named only by a bare Swift literal is not looked up by it.
                self.assertNotReferenced(.functionMethodInstance("namedInSwiftLiteral()"))
                self.assertConfidence(.functionMethodInstance("namedInSwiftLiteral()"), .certain)
            }
            assertNotReferenced(.class("FixtureClass240Loaded"))
            if hasClangUnits {
                assertConfidence(.class("FixtureClass240Loaded"), .likely)
            }
        }
    }

    func testPlanRecordsCompleteClangCoverage() throws {
        // Where the fixture package writes no clang units its C targets are unbuilt, so nothing is missing.
        let coverage = try XCTUnwrap(Self.plan?.clangCoverage)
        XCTAssertEqual(coverage.unindexedFiles, [])
        XCTAssertTrue(coverage.isComplete)
    }

    func testPlanKeepsClangFilesOutOfSwiftSourceFiles() throws {
        let plan = try XCTUnwrap(Self.plan)
        let swiftNames = plan.sourceFiles.keys.compactMap { $0.path.lastComponent?.string }
        let clangNames = plan.clangSourceFiles.keys.compactMap { $0.path.lastComponent?.string }
        var clangFiles = ["ClangUnitSupport.c"]
        #if os(macOS)
            clangFiles.append("ClangUnitObjcSupport.m")
        #else
            // SwiftPM in the Swift 6.4 Linux image writes no index units for C targets.
            if clangNames.isEmpty {
                XCTAssertFalse(swiftNames.contains("ClangUnitSupport.c"))
                throw XCTSkip("SwiftPM wrote no clang index units for the C fixture target")
            }
        #endif

        for name in clangFiles {
            XCTAssertTrue(clangNames.contains(name), "\(name) not in clang files: \(clangNames.sorted())")
            XCTAssertFalse(swiftNames.contains(name), name)
        }
        XCTAssertTrue(swiftNames.contains("testClangLiteralsAreConfidenceEvidence.swift"))
        XCTAssertFalse(clangNames.contains("testClangLiteralsAreConfidenceEvidence.swift"))
    }

    func testClassifiesUnitsByProviderThenMainFileExtension() {
        XCTAssertTrue(SourceFileCollector.isClangUnit(providerIdentifier: "clang", mainFile: "/p/File.m"))
        XCTAssertFalse(SourceFileCollector.isClangUnit(providerIdentifier: "swift", mainFile: "/p/File.swift"))
        // The provider wins over the extension.
        XCTAssertFalse(SourceFileCollector.isClangUnit(providerIdentifier: "swift", mainFile: "/p/File.h"))

        for file in ["/p/File.m", "/p/File.mm", "/p/File.c", "/p/File.cpp", "/p/File.H"] {
            XCTAssertTrue(SourceFileCollector.isClangUnit(providerIdentifier: "", mainFile: file), file)
        }
        for file in ["/p/File.swift", "/p/File"] {
            XCTAssertFalse(SourceFileCollector.isClangUnit(providerIdentifier: "", mainFile: file), file)
        }
    }
}

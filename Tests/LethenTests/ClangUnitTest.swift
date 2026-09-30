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

    private var swiftSourcePath: FilePath {
        FixturesProjectPath.appending("Sources/ClangUnitFixtures/testClangLiteralsAreNotConfidenceEvidence.swift")
    }

    func testClangLiteralsAreNotConfidenceEvidence() throws {
        try analyze(retainPublic: true, additionalFilesToIndex: [clangSourcePath, objcSourcePath]) {
            assertReferenced(.class("FixtureClass240")) {
                // Named only in C and Objective-C string literals, which Swift does not look up.
                self.assertNotReferenced(.functionMethodInstance("namedInClangLiteral()"))
                self.assertConfidence(.functionMethodInstance("namedInClangLiteral()"), .certain)
                self.assertNotReferenced(.functionMethodInstance("namedInSwiftLiteral()"))
                self.assertConfidence(.functionMethodInstance("namedInSwiftLiteral()"), .likely)
            }
        }
    }

    func testPlanKeepsClangFilesOutOfSwiftSourceFiles() throws {
        let plan = try XCTUnwrap(Self.plan)
        var clangPaths = [clangSourcePath]
        #if os(macOS)
            clangPaths.append(objcSourcePath)
        #endif

        for path in clangPaths {
            XCTAssertTrue(plan.clangSourceFiles.keys.contains { $0.path == path }, path.string)
            XCTAssertFalse(plan.sourceFiles.keys.contains { $0.path == path }, path.string)
        }
        XCTAssertTrue(plan.sourceFiles.keys.contains { $0.path == swiftSourcePath })
        XCTAssertFalse(plan.clangSourceFiles.keys.contains { $0.path == swiftSourcePath })
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

import Configuration
@testable import Indexer
import Logger
import Shared
@testable import SourceGraph
import SystemPackage
import XCTest

/// The marker's treatment of C and Objective-C imports, which clang's index cannot place in a SwiftPM
/// fixture: the referenced modules are given to the files by hand, as the Objective-C indexer would.
final class UnusedImportMarkerTest: XCTestCase {
    private let path = FilePath("/project/File.m")

    func testNameMatchingIsByModulePath() {
        // The same module, and a submodule on either side of it.
        XCTAssertTrue(UnusedImportMarker.isModule("WMF", referencedIn: ["WMF"]))
        XCTAssertTrue(UnusedImportMarker.isModule("WMF", referencedIn: ["WMF.WMFLogging"]))
        XCTAssertTrue(UnusedImportMarker.isModule("WMF.WMFLogging", referencedIn: ["WMF"]))
        XCTAssertTrue(UnusedImportMarker.isModule("WMF.WMFLogging", referencedIn: ["WMF.WMFLogging"]))
        // A sibling submodule, and a module whose name merely starts with the import's.
        XCTAssertFalse(UnusedImportMarker.isModule("WMF.WMFLogging", referencedIn: ["WMF.Swift"]))
        XCTAssertFalse(UnusedImportMarker.isModule("WMF", referencedIn: ["WMFData"]))
        XCTAssertFalse(UnusedImportMarker.isModule("WMFData", referencedIn: ["WMF"]))
        XCTAssertFalse(UnusedImportMarker.isModule("WMF", referencedIn: []))
    }

    private func unusedImports(
        referencing referenced: Set<String>,
        statements: [(qualified: String, isConditional: Bool, commands: [CommentCommand])] = [("WMF.WMFLogging", false, [])],
        configure: (Configuration) -> Void = { _ in },
        indexedModules: Set<String> = ["WMF"]
    ) throws -> [String] {
        let configuration = Configuration()
        configure(configuration)
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let graph = SourceGraph(configuration: configuration, logger: logger)
        let file = SourceFile(path: path, modules: [])
        file.importStatements = statements.enumerated().map { offset, statement in
            ImportStatement(
                module: String(statement.qualified.prefix { $0 != "." }),
                qualifiedModule: statement.qualified,
                isTestable: false,
                isExported: false,
                isConditional: statement.isConditional,
                location: Location(file: file, line: offset + 1, column: 1),
                commentCommands: statement.commands
            )
        }
        file.clangReferencedModules = referenced
        graph.addIndexedSourceFile(file)
        graph.addIndexedModules(indexedModules)

        let shell = ShellImpl(logger: logger)
        try UnusedImportMarker(graph: graph, configuration: configuration, swiftVersion: SwiftVersion(shell: shell)).mutate()
        return graph.unusedModuleImports.map(\.name).sorted()
    }

    func testReportsSubmoduleImportThatNothingReferences() throws {
        XCTAssertEqual(try unusedImports(referencing: []), ["WMF.WMFLogging"])
        // Another submodule of the same module is not a use of this one.
        XCTAssertEqual(try unusedImports(referencing: ["WMF.Swift"]), ["WMF.WMFLogging"])
    }

    func testKeepsImportWhoseSubmoduleOrModuleIsReferenced() throws {
        XCTAssertEqual(try unusedImports(referencing: ["WMF.WMFLogging"]), [])
        XCTAssertEqual(try unusedImports(referencing: ["WMF"]), [])
    }

    func testOnlyIndexedModulesAreChecked() throws {
        XCTAssertEqual(try unusedImports(referencing: [], indexedModules: []), [])
    }

    func testKeepsConditionalAndIgnoredImports() throws {
        XCTAssertEqual(try unusedImports(referencing: [], statements: [("WMF.WMFLogging", true, [])]), [])
        XCTAssertEqual(try unusedImports(referencing: [], statements: [("WMF.WMFLogging", false, [.ignore])]), [])
        XCTAssertEqual(try unusedImports(referencing: [], statements: [("WMF.WMFLogging", false, [.ignoreAll])]), [])
    }

    func testKeepsRetainedModulesByTopLevelOrQualifiedName() throws {
        XCTAssertEqual(try unusedImports(referencing: [], configure: { $0.retainUnusedImportedModules = ["WMF"] }), [])
        XCTAssertEqual(try unusedImports(referencing: [], configure: { $0.retainUnusedImportedModules = ["WMF.WMFLogging"] }), [])
        XCTAssertEqual(try unusedImports(referencing: [], configure: { $0.retainUnusedImportedModules = ["WMFData"] }), ["WMF.WMFLogging"])
    }

    func testDisabledAnalysisReportsNothing() throws {
        XCTAssertEqual(try unusedImports(referencing: [], configure: { $0.disableUnusedImportAnalysis = true }), [])
    }

    func testRetainedFilesAreNotChecked() throws {
        XCTAssertEqual(try unusedImports(referencing: [], configure: { $0.retainFiles = ["/project/*.m"]; $0.buildFilenameMatchers() }), [])
    }

    /// The imports the scanner reads from `source`, run through the marker with `referenced` as the modules
    /// the file uses.
    private func unusedImports(inSource source: String, referencing referenced: Set<String>) throws -> [String] {
        let configuration = Configuration()
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let graph = SourceGraph(configuration: configuration, logger: logger)
        let file = SourceFile(path: path, modules: [])
        file.importStatements = ClangImportScanner.imports(in: Array(source.utf8), file: file)
        file.clangReferencedModules = referenced
        graph.addIndexedSourceFile(file)
        graph.addIndexedModules(["WMF"])

        let shell = ShellImpl(logger: logger)
        try UnusedImportMarker(graph: graph, configuration: configuration, swiftVersion: SwiftVersion(shell: shell)).mutate()
        return graph.unusedModuleImports.map(\.name).sorted()
    }

    /// An `@import` with blanks or comments between the tokens is reported when nothing uses it, retained
    /// when something does, and retained when an ignore comment sits between the tokens.
    func testSpacedImportsAreReportedWhenUnusedAndRetainedWhenUsed() throws {
        for spelling in ["@import WMF;", "@ import WMF;", "@/* note */import WMF;", "@\n import WMF;", "@\u{0C}import WMF;", "@\u{0B}import WMF;"] {
            XCTAssertEqual(try unusedImports(inSource: spelling + "\n", referencing: []), ["WMF"], spelling)
            XCTAssertEqual(try unusedImports(inSource: spelling + "\n", referencing: ["WMF"]), [], spelling)
        }
        XCTAssertEqual(try unusedImports(inSource: "@ /* periphery:ignore */ import WMF;\n", referencing: []), [])
        XCTAssertEqual(try unusedImports(inSource: "@import Other;\n@/* periphery:ignore:all */import WMF;\n", referencing: []), [])
    }
}

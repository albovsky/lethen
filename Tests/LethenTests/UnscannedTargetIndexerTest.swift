import Configuration
@testable import Indexer
import Logger
@testable import SourceGraph
import SystemPackage
import XCTest

/// The names an unscanned target's own Swift files use reach the graph with sites relative to the project
/// root; a file the target shares with a scanned target is indexed there and is not read again.
final class UnscannedTargetIndexerTest: XCTestCase {
    private var root: FilePath!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lethen-unscanned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = FilePath(directory.path)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: root.string)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ contents: String) throws -> FilePath {
        let path = root.appending(name)
        try contents.write(toFile: path.string, atomically: true, encoding: .utf8)
        return path
    }

    func testRecordsNamesWithSitesRelativeToTheProjectRoot() throws {
        let own = try write("Widgets.swift", "import Shared\n\nlet widget = SearchWidget()\nlet width = Store.shared.width\n")
        let shared = try write("SearchWidget.swift", "struct SearchWidget { let entry: SearchEntry }\nstruct SearchEntry {}\n")
        let configuration = Configuration()
        configuration.projectRoot = root
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let graph = SourceGraph(configuration: configuration, logger: logger)

        try UnscannedTargetIndexer(
            targets: [UnscannedTarget(name: "WidgetsExtension", swiftSourceFiles: [own, shared], sharedSourceFiles: [shared])],
            graph: SourceGraphMutex(graph: graph),
            logger: logger.contextualized(with: "test"),
            configuration: configuration
        ).perform()

        let names = try XCTUnwrap(graph.unscannedTargetNames["WidgetsExtension"])
        XCTAssertEqual(names.names["SearchWidget"], "Widgets.swift:3")
        XCTAssertEqual(names.names["Store"], "Widgets.swift:4")
        XCTAssertEqual(names.memberNames["shared"], "Widgets.swift:4")
        XCTAssertEqual(names.constructionNames["width"], "Widgets.swift:4")
        // Spelled only in the shared file, which the scanned target's index already covers.
        XCTAssertNil(names.names["SearchEntry"])
        XCTAssertNil(names.names["Shared"], "an import path is not a use")
        XCTAssertEqual(names.sharedSourceFiles, [shared.lexicallyNormalized()])
    }

    func testUnreadableFileIsSkipped() throws {
        let own = try write("Fine.swift", "let value = Named()\n")
        let configuration = Configuration()
        configuration.projectRoot = root
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let graph = SourceGraph(configuration: configuration, logger: logger)

        try UnscannedTargetIndexer(
            targets: [UnscannedTarget(name: "T", swiftSourceFiles: [own, root.appending("Missing.swift")], sharedSourceFiles: [])],
            graph: SourceGraphMutex(graph: graph),
            logger: logger.contextualized(with: "test"),
            configuration: configuration
        ).perform()

        XCTAssertEqual(graph.unscannedTargetNames["T"]?.names["Named"], "Fine.swift:1")
    }
}

import Configuration
import Foundation
import Indexer
import Logger
import Shared
import SystemPackage
@testable import TestShared
import XCTest

/// `requireFreshUnits` is for stores lethen did not just build: a source edited after it was indexed must
/// fail the scan instead of being analyzed from its old unit.
final class SourceFileCollectorFreshnessTest: XCTestCase {
    private var root: FilePath!
    private var store: FilePath!
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    override func setUpWithError() throws {
        root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen collector freshness \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        let fixture = ProjectRootPath.appending("Tests/IndexStoreDiscoveryProject")
        for input in ["Package.swift", "Sources"] {
            try FileManager.default.copyItem(at: fixture.appending(input).url, to: root.appending(input).url)
        }

        try root.chdir {
            let shell = ShellImpl(logger: logger)
            // swiftbuild appends its own -index-store-path under the bin path, so that is where units go.
            try shell.exec(["swift", "build", "--enable-index-store"])
            let binary = try shell.exec(["swift", "build", "--show-bin-path", "--enable-index-store"]).trimmingCharacters(in: .whitespacesAndNewlines)
            store = FilePath(binary).appending("index/store")
        }
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root.url)
        }
    }

    func testFreshStoreIsCollected() throws {
        let files = try collect(requireFreshUnits: true)

        XCTAssertTrue(files.contains("main.swift"), "\(files)")
        XCTAssertTrue(files.contains("PublicEnumWithAssociatedValue.swift"), "\(files)")
    }

    func testSourceEditedAfterIndexingFailsTheScan() throws {
        let main = root.appending("Sources/MainTarget/main.swift")
        let text = try String(contentsOf: main.url, encoding: .utf8)
        try (text + "\n// edited after indexing\n").write(to: main.url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try collect(requireFreshUnits: true)) { error in
            guard case let LethenError.staleIndexStore(_, staleFiles) = error else {
                return XCTFail("Expected a stale index error, got \(error)")
            }

            XCTAssertEqual(staleFiles.map { FilePath($0).lastComponent?.string }, ["main.swift"])
        }
    }

    /// An explicit --index-store-path stays authoritative, so the same store is used as-is.
    func testEditedSourceIsCollectedWhenFreshnessIsNotRequired() throws {
        let main = root.appending("Sources/MainTarget/main.swift")
        let text = try String(contentsOf: main.url, encoding: .utf8)
        try (text + "\n// edited after indexing\n").write(to: main.url, atomically: true, encoding: .utf8)

        XCTAssertTrue(try collect(requireFreshUnits: false).contains("main.swift"))
    }

    // MARK: - Private

    private func collect(requireFreshUnits: Bool) throws -> Set<String> {
        var names: Set<String> = []
        try root.chdir {
            let collector = SourceFileCollector(
                indexStorePaths: [store],
                excludedTestTargets: [],
                requireFreshUnits: requireFreshUnits,
                logger: logger.contextualized(with: "test"),
                configuration: Configuration()
            )
            names = try Set(collector.collect().keys.compactMap { $0.path.lastComponent?.string })
        }
        return names
    }
}

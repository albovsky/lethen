import Configuration
import Foundation
@testable import Indexer
import IndexStore
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

    /// Units for two versions of one file, as an Xcode index built for several destinations over time
    /// holds, give conflicting declarations; only the current version is indexed.
    func testOnlyTheCurrentVersionOfAFileIsIndexed() throws {
        let twoVersions = try buildTwoVersionsOfMain()

        XCTAssertEqual(try symbols(inUnitsOf: "main.swift", store: twoVersions, requireFreshUnits: false), [["versionTwoOnly()"]])
    }

    /// When the file changed after every unit, the most recently written version is used, and only it.
    func testTheNewestVersionIsIndexedWhenEveryUnitIsOlderThanTheFile() throws {
        let twoVersions = try buildTwoVersionsOfMain()
        try append("\nfunc versionThreeOnly() {}\n", to: "Sources/MainTarget/main.swift")

        XCTAssertEqual(try symbols(inUnitsOf: "main.swift", store: twoVersions, requireFreshUnits: false), [["versionTwoOnly()"]])
        XCTAssertThrowsError(try symbols(inUnitsOf: "main.swift", store: twoVersions, requireFreshUnits: true))
    }

    /// With one store per configuration, each store must be current on its own: a source edited after one store
    /// was written and then rebuilt into another must not hide the first store's older units.
    func testEveryStoreMustBeCurrentForAFileItIndexed() throws {
        let rebuilt = root.appending("rebuilt")
        Thread.sleep(forTimeInterval: 1.1)
        try append("\n// edited after indexing\n", to: "Sources/MainTarget/main.swift")
        try root.chdir {
            let arguments = ["--build-system", "native", "-c", "release", "-Xswiftc", "-index-store-path", "-Xswiftc", "'\(rebuilt.string)'"]
            try ShellImpl(logger: logger).exec(["swift", "build"] + arguments)
        }

        XCTAssertThrowsError(try collect(stores: [store, rebuilt], requireFreshUnits: true)) { error in
            guard case let LethenError.staleIndexStore(path, staleFiles) = error else {
                return XCTFail("Expected a stale index error, got \(error)")
            }

            XCTAssertEqual(path, store.string)
            XCTAssertEqual(staleFiles.map { FilePath($0).lastComponent?.string }, ["main.swift"])
        }
        XCTAssertTrue(try collect(stores: [rebuilt], requireFreshUnits: true).contains("main.swift"))
        XCTAssertTrue(try collect(stores: [store, rebuilt], requireFreshUnits: false).contains("main.swift"))
    }

    // MARK: - Private

    /// Builds main.swift into one store twice, in debug and in release so the units do not replace each
    /// other, adding a function between the builds.
    private func buildTwoVersionsOfMain() throws -> FilePath {
        let twoVersions = root.appending("two-versions")
        try root.chdir {
            let shell = ShellImpl(logger: logger)
            let arguments = ["--build-system", "native", "-Xswiftc", "-index-store-path", "-Xswiftc", "'\(twoVersions.string)'"]
            try append("\nfunc versionOneOnly() {}\n", to: "Sources/MainTarget/main.swift")
            try shell.exec(["swift", "build", "-c", "debug"] + arguments)
            // A second build a moment later, so the two versions' units have different dates.
            Thread.sleep(forTimeInterval: 1.1)
            try replace("versionOneOnly", with: "versionTwoOnly", in: "Sources/MainTarget/main.swift")
            try shell.exec(["swift", "build", "-c", "release"] + arguments)
        }
        return twoVersions
    }

    /// The probe declarations in each unit collected for the file, one set per unit.
    private func symbols(inUnitsOf fileName: String, store: FilePath, requireFreshUnits: Bool) throws -> [Set<String>] {
        var result: [Set<String>] = []
        try root.chdir {
            let collector = SourceFileCollector(
                indexStorePaths: [store],
                excludedTestTargets: [],
                requireFreshUnits: requireFreshUnits,
                logger: logger.contextualized(with: "test"),
                configuration: Configuration()
            )
            for (file, units) in try collector.collect().sourceFiles where file.path.lastComponent?.string == fileName {
                for unit in units {
                    var names: Set<String> = []
                    for recordName in unit.unit.recordNames {
                        let record = try RecordReader(indexStore: unit.store, recordName: recordName)
                        record.forEach(symbol: { symbol in
                            if symbol.name.hasPrefix("version") {
                                names.insert(symbol.name)
                            }
                        })
                    }
                    result.append(names)
                }
            }
        }
        return result
    }

    private func append(_ text: String, to relativePath: String) throws {
        let url = root.appending(relativePath).url
        try (String(contentsOf: url, encoding: .utf8) + text).write(to: url, atomically: true, encoding: .utf8)
    }

    private func replace(_ old: String, with new: String, in relativePath: String) throws {
        let url = root.appending(relativePath).url
        try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
    }

    private func collect(stores: Set<FilePath>? = nil, requireFreshUnits: Bool) throws -> Set<String> {
        var names: Set<String> = []
        try root.chdir {
            let collector = SourceFileCollector(
                indexStorePaths: stores ?? [store],
                excludedTestTargets: [],
                requireFreshUnits: requireFreshUnits,
                logger: logger.contextualized(with: "test"),
                configuration: Configuration()
            )
            names = try Set(collector.collect().sourceFiles.keys.compactMap { $0.path.lastComponent?.string })
        }
        return names
    }
}

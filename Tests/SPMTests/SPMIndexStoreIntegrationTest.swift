import Configuration
import Foundation
import IndexStore
import Logger
@testable import ProjectDrivers
import Shared
import SystemPackage
@testable import TestShared
import XCTest

final class SPMIndexStoreIntegrationTest: XCTestCase {
    private var fixturePath: FilePath {
        ProjectRootPath.appending("Tests/IndexStoreDiscoveryProject")
    }

    func testDefaultAndNativeStoresRemainIndependentWithCustomScratchPaths() throws {
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let shell = ShellImpl(logger: logger)
        let root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen build space \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.url) }

        try fixturePath.chdir {
            let modes: [[String]] = [[], ["--build-system", "native"]]
            var configurations: [Configuration] = []
            var stores: [FilePath] = []
            for (offset, mode) in modes.enumerated() {
                let configuration = Configuration()
                configuration.buildArguments = mode + ["--scratch-path", root.appending("mode-\(offset)").string, "-c", "release"]
                let driver = try SPMProjectDriver(configuration: configuration, shell: shell, logger: logger)
                if offset == 0 {
                    // Reproduce a warm, automatically indexed build. Release auto
                    // indexing emits no store, and changing flags alone can reuse it.
                    try shell.exec(["swift", "build", "--build-tests"] + configuration.buildArguments + ["--auto-index-store"])
                }
                try driver.build()
                let pkg = SPM.Package(configuration: configuration, shell: shell, logger: logger)
                try stores.append(pkg.indexStorePath(additionalArguments: configuration.buildArguments))
                configurations.append(configuration)
                try assertFixtureCoverage(driver, logger: logger)
            }
            XCTAssertNotEqual(stores[0], stores[1])
            // Revisit both while both stores exist; skip-build still selects the active build.
            for configuration in configurations {
                configuration.skipBuild = true
                let driver = try SPMProjectDriver(configuration: configuration, shell: shell, logger: logger)
                try driver.build()
                try assertFixtureCoverage(driver, logger: logger)
            }
            let first = configurations[0]
            let pkg = SPM.Package(configuration: first, shell: shell, logger: logger)
            try pkg.clean(additionalArguments: first.buildArguments)
            XCTAssertThrowsError(try pkg.indexStorePath(additionalArguments: first.buildArguments))
            XCTAssertTrue(stores[1].exists, "Cleaning one scratch root must preserve the other engine's store")
        }
    }

    func testManagedBuildRefreshesExistingStoreAfterUnindexedSourceChange() throws {
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let shell = ShellImpl(logger: logger)
        let root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen stale index \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        for input in ["Package.swift", "Sources"] {
            try FileManager.default.copyItem(at: fixturePath.appending(input).url, to: root.appending(input).url)
        }
        defer { try? FileManager.default.removeItem(at: root.url) }

        try root.chdir {
            let configuration = Configuration()
            let pkg = SPM.Package(configuration: configuration, shell: shell, logger: logger)
            try pkg.clean()
            try pkg.build(additionalArguments: [])
            let source = root.appending("Sources/MainTarget/main.swift")
            let text = try String(contentsOf: source.url, encoding: .utf8)
            try (text + "\nfunc staleProbeUnused() {}\n").write(to: source.url, atomically: true, encoding: .utf8)
            try shell.exec(["swift", "build", "--disable-index-store"])
            try pkg.build(additionalArguments: [])

            let store = try IndexStore(path: pkg.indexStorePath(additionalArguments: []).string)
            var names: Set<String> = []
            for unit in store.units {
                guard URL(fileURLWithPath: unit.mainFile).resolvingSymlinksInPath() == source.url.resolvingSymlinksInPath() else { continue }

                for recordName in unit.recordNames {
                    let record = try RecordReader(indexStore: store, recordName: recordName)
                    record.forEach(symbol: { names.insert($0.name) })
                }
            }
            XCTAssertTrue(names.contains("staleProbeUnused()"), "A managed scan must index the current source after an external unindexed build")
        }
    }

    /// The CI route the guide documents: the pipeline builds with `--enable-index-store`, then `lethen scan
    /// --skip-build` finds that store from the build arguments and verifies it, while `--index-store-path` on the same
    /// store stays authoritative and unchecked.
    func testSkipBuildVerifiesAPipelineBuildThatIndexStorePathDoesNot() throws {
        let logger = Logger(quiet: true, verbose: false, colorMode: .never)
        let shell = ShellImpl(logger: logger)
        let root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen pipeline build \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        for input in ["Package.swift", "Sources"] {
            try FileManager.default.copyItem(at: fixturePath.appending(input).url, to: root.appending(input).url)
        }
        defer { try? FileManager.default.removeItem(at: root.url) }

        try root.chdir {
            try shell.exec(["swift", "build", "--build-tests", "--enable-index-store"])
            let verified = Configuration()
            verified.skipBuild = true
            let store = try SPM.Package(configuration: verified, shell: shell, logger: logger).indexStorePath(additionalArguments: [])

            // Fresh: the verified route scans the pipeline's store.
            let fresh = try SPMProjectDriver(configuration: verified, shell: shell, logger: logger)
                .plan(logger: logger.contextualized(with: "test"))
            XCTAssertTrue(fresh.sourceFiles.keys.contains { $0.path.lastComponent?.string == "main.swift" })

            // A build argument the pipeline did not build with names another build, which has no store.
            let mismatched = Configuration()
            mismatched.skipBuild = true
            mismatched.buildArguments = ["-c", "release"]
            XCTAssertThrowsError(try SPMProjectDriver(configuration: mismatched, shell: shell, logger: logger).plan(logger: logger.contextualized(with: "test")))

            let main = root.appending("Sources/MainTarget/main.swift")
            let text = try String(contentsOf: main.url, encoding: .utf8)
            try (text + "\n// edited after the pipeline's build\n").write(to: main.url, atomically: true, encoding: .utf8)

            // Stale: the verified route fails, naming the edited file.
            XCTAssertThrowsError(try SPMProjectDriver(configuration: verified, shell: shell, logger: logger).plan(logger: logger.contextualized(with: "test"))) { error in
                guard case let LethenError.staleIndexStore(_, staleFiles) = error else {
                    return XCTFail("Expected a stale index error, got \(error)")
                }

                XCTAssertEqual(staleFiles.map { FilePath($0).lastComponent?.string }, ["main.swift"])
            }

            // `--index-store-path` on the same store is not checked, and still scans.
            let explicit = Configuration()
            explicit.skipBuild = true
            explicit.indexStorePath = [store]
            let unchecked = try SPMProjectDriver(configuration: explicit, shell: shell, logger: logger)
                .plan(logger: logger.contextualized(with: "test"))
            XCTAssertTrue(unchecked.sourceFiles.keys.contains { $0.path.lastComponent?.string == "main.swift" })
        }
    }

    private func assertFixtureCoverage(_ driver: SPMProjectDriver, logger: Logger) throws {
        let plan = try driver.plan(logger: logger.contextualized(with: "test"))
        let paths = Set(plan.sourceFiles.keys.map { $0.path.relativeTo(fixturePath).string })
        for path in ["Sources/MainTarget/main.swift", "Sources/ExternalTarget/ExternalProtocol.swift", "Sources/TargetA/PublicEnumWithAssociatedValue.swift"] {
            XCTAssertTrue(paths.contains(path), "Active index is missing \(path)")
        }
    }
}

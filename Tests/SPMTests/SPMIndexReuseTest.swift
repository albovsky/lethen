import Configuration
import Foundation
import IndexStore
import Logger
@testable import ProjectDrivers
import Shared
import Synchronization
import SystemPackage
@testable import TestShared
import XCTest

/// A managed SwiftPM scan reuses its build only when SPMIndexFreshness verifies it. Every test builds a
/// private copy of IndexStoreDiscoveryProject for real, then checks both whether lethen cleaned and what
/// the store holds for the edited files, so a reused store is proven current rather than assumed.
final class SPMIndexReuseTest: XCTestCase {
    private var root: FilePath!
    private var shell: RecordingShell!
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    override func setUpWithError() throws {
        root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen index reuse \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        let fixture = ProjectRootPath.appending("Tests/IndexStoreDiscoveryProject")
        for input in ["Package.swift", "Sources"] {
            try FileManager.default.copyItem(at: fixture.appending(input).url, to: root.appending(input).url)
        }
        shell = RecordingShell(ShellImpl(logger: logger))
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root.url)
        }
    }

    func testUnindexedTreeIsCleanedAndStamped() throws {
        try root.chdir {
            try shell.exec(["swift", "build", "--build-tests", "--disable-index-store"])

            try build()

            XCTAssertTrue(shell.cleaned, "An existing tree without a stamp must be cleaned")
            XCTAssertTrue(try freshness().readStamp() != nil)
            XCTAssertTrue(try symbols(in: "Sources/MainTarget/main.swift").contains("PublicEnumWithAssociatedValue"))
        }
    }

    func testRescanWithoutChangesDoesNotClean() throws {
        try root.chdir {
            try build()
            shell.reset()

            try build()

            XCTAssertFalse(shell.cleaned)
            XCTAssertTrue(try freshness().readStamp() != nil)
        }
    }

    func testFileRecompiledByAnUnindexedBuildIsReindexedWithoutCleaning() throws {
        try root.chdir {
            try append("\nfunc reuseProbeBefore() {}\n", to: "Sources/MainTarget/main.swift")
            try build()
            try replace("reuseProbeBefore", with: "reuseProbeAfter", in: "Sources/MainTarget/main.swift")
            try shell.exec(["swift", "build", "--build-tests", "--disable-index-store"])
            shell.reset()

            try build()

            XCTAssertFalse(shell.cleaned)
            let names = try symbols(in: "Sources/MainTarget/main.swift")
            XCTAssertTrue(names.contains("reuseProbeAfter()"), "The declaration the unindexed build compiled must be indexed")
            XCTAssertFalse(names.contains("reuseProbeBefore()"), "The replaced declaration must not survive in the store")
        }
    }

    /// The caller's source is unchanged, but the unindexed build recompiles it against the new interface.
    /// An enum case's USR includes its payload type, so a stale caller record would still reference the
    /// Int case and leave the Int64 case looking unused.
    func testCallerRecompiledByAnInterfaceChangeIsReindexed() throws {
        try root.chdir {
            try build()
            let enumFile = "Sources/TargetA/PublicEnumWithAssociatedValue.swift"
            try replace("case number(Int)", with: "case number(Int64)", in: enumFile)
            try replace("case let .number(value): value", with: "case let .number(value): Int(value)", in: enumFile)
            try shell.exec(["swift", "build", "--build-tests", "--disable-index-store"])
            shell.reset()

            try build()

            XCTAssertFalse(shell.cleaned)
            let caseUSRs = try usrs(named: "number(_:)", in: "Sources/MainTarget/main.swift")
            XCTAssertFalse(caseUSRs.isEmpty, "main.swift must still reference number(_:)")
            XCTAssertTrue(caseUSRs.allSatisfy { $0.contains("s5Int64V") }, "main.swift must reference the Int64 case, found \(caseUSRs)")
        }
    }

    func testFileAddedByAnUnindexedBuildIsIndexedWithoutCleaning() throws {
        try root.chdir {
            try build()
            try "func reuseProbeNewFile() {}\n".write(to: root.appending("Sources/MainTarget/Added.swift").url, atomically: true, encoding: .utf8)
            try shell.exec(["swift", "build", "--build-tests", "--disable-index-store"])
            shell.reset()

            try build()

            XCTAssertFalse(shell.cleaned)
            XCTAssertTrue(try symbols(in: "Sources/MainTarget/Added.swift").contains("reuseProbeNewFile()"))
        }
    }

    /// SwiftPM does not rebuild when only -Xswiftc flags change, so a stamp for other arguments cannot
    /// vouch for the objects in the tree.
    func testChangedBuildArgumentsClean() throws {
        try root.chdir {
            try build()
            shell.reset()

            try build(arguments: ["-Xswiftc", "-DLETHEN_REUSE_PROBE"])

            XCTAssertTrue(shell.cleaned)
        }
    }

    func testVerifyReportsASourceCompiledOnlyWithoutIndexing() throws {
        try root.chdir {
            try build()
            try "func reuseProbeNewFile() {}\n".write(to: root.appending("Sources/MainTarget/Added.swift").url, atomically: true, encoding: .utf8)
            try shell.exec(["swift", "build", "--build-tests", "--disable-index-store"])

            let issues = try freshness().verify(sources: package().packageSources(), buildStart: .distantPast)

            XCTAssertTrue(issues.contains {
                if case let .missingUnit(path) = $0 {
                    path.lastComponent?.string == "Added.swift"
                } else {
                    false
                }
            }, "\(issues)")
        }
    }

    func testPreparationRecompilesImportersOfAChangedModule() throws {
        try root.chdir {
            try build()
            let stamp = try XCTUnwrap(freshness().readStamp())
            try replace("case number(Int)", with: "case number(Int64)", in: "Sources/TargetA/PublicEnumWithAssociatedValue.swift")
            try replace("case let .number(value): value", with: "case let .number(value): Int(value)", in: "Sources/TargetA/PublicEnumWithAssociatedValue.swift")
            try shell.exec(["swift", "build", "--build-tests", "--disable-index-store"])

            let preparation = try freshness().prepare(sources: package().packageSources(), stampDate: stamp.date)

            guard case let .recompile(objects, modules) = preparation else {
                return XCTFail("Expected a recompile, got \(preparation)")
            }

            // The native build system tracks compiler flags, so its unindexed build recompiles, and dirties,
            // every module; swiftbuild recompiles only TargetA. Either way the importer must be included.
            XCTAssertTrue(modules.isSuperset(of: ["TargetA", "MainTarget"]), "\(modules)")
            // swiftbuild names objects main.o, the native build system main.swift.o.
            XCTAssertTrue(objects.contains { $0.lastComponent?.string.hasPrefix("main.") == true }, "\(objects)")
        }
    }

    func testPreparationCleansForAnObjectNoIndexedModuleOwns() throws {
        try root.chdir {
            try build()
            let freshness = try freshness()
            let stamp = try XCTUnwrap(freshness.readStamp())
            let intermediates = freshness.buildRoot.appending("Intermediates.noindex")
            let directory = (FileManager.default.fileExists(atPath: intermediates.string) ? intermediates : freshness.buildRoot)
                .appending("Unindexed.build")
            try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
            try Data().write(to: directory.appending("Unindexed.o").url)

            let preparation = try freshness.prepare(sources: package().packageSources(), stampDate: stamp.date)

            guard case .clean = preparation else {
                return XCTFail("Expected a clean, got \(preparation)")
            }
        }
    }

    /// A unit for a file the package no longer builds would still be analyzed, because the file exists.
    /// swiftbuild deletes the excluded file's object, so its unit no longer resolves; the native build
    /// system leaves the object and unit in place, so only the package source check catches it.
    func testSourceExcludedFromThePackageIsNotReused() throws {
        for (index, buildSystem) in [[], ["--build-system", "native"]].enumerated() {
            if index > 0 {
                // Each build system starts from a fresh copy of the fixture.
                try tearDownWithError()
                try setUpWithError()
            }
            try root.chdir {
                try "func reuseProbeExcluded() {}\n".write(to: root.appending("Sources/MainTarget/Added.swift").url, atomically: true, encoding: .utf8)
                try build(arguments: buildSystem)
                XCTAssertTrue(try symbols(in: "Sources/MainTarget/Added.swift", arguments: buildSystem).contains("reuseProbeExcluded()"))
                try replace(
                    #".executableTarget(name: "MainTarget", dependencies: ["TargetA"])"#,
                    with: #".executableTarget(name: "MainTarget", dependencies: ["TargetA"], exclude: ["Added.swift"])"#,
                    in: "Package.swift"
                )
                shell.reset()

                try build(arguments: buildSystem)

                XCTAssertTrue(shell.cleaned, "\(buildSystem): a unit for an excluded source must not be reused")
                XCTAssertTrue(try symbols(in: "Sources/MainTarget/Added.swift", arguments: buildSystem).isEmpty, "\(buildSystem): the excluded source must have no unit")
                XCTAssertTrue(try symbols(in: "Sources/MainTarget/main.swift", arguments: buildSystem).contains("PublicEnumWithAssociatedValue"), "\(buildSystem): current sources stay indexed")
            }
        }
    }

    func testUnreadableStoreFallsBackToCleaning() throws {
        try root.chdir {
            try build()
            let store = try freshness().storePath
            for entry in try FileManager.default.contentsOfDirectory(atPath: store.string) {
                try FileManager.default.removeItem(atPath: store.appending(entry).string)
            }
            shell.reset()

            try build()

            XCTAssertTrue(shell.cleaned)
            XCTAssertTrue(try symbols(in: "Sources/MainTarget/main.swift").contains("PublicEnumWithAssociatedValue"))
        }
    }

    func testModuleNamesComeFromThePackageDescription() throws {
        try root.chdir {
            let modules = try Set(package().packageSources().map(\.module))

            XCTAssertEqual(modules, ["ExternalTarget", "TargetA", "MainTarget"])
        }
    }

    // MARK: - Private

    private func build(arguments: [String] = []) throws {
        try package().build(additionalArguments: arguments)
    }

    private func package() -> SPM.Package {
        let configuration = Configuration()
        return SPM.Package(configuration: configuration, shell: shell, logger: logger)
    }

    private func freshness(arguments: [String] = []) throws -> SPMIndexFreshness {
        let binary = try FilePath(ShellImpl(logger: logger).exec(["swift", "build", "--show-bin-path"] + arguments + ["--enable-index-store"]).trimmingCharacters(in: .whitespacesAndNewlines))
        return try SPMIndexFreshness(
            storePath: SPMIndexStoreLocator.indexStorePath(binPath: binary),
            buildRoot: binary.removingLastComponent().removingLastComponent(),
            packageRoot: root
        )
    }

    /// Symbol names in the records the store's units currently point at for the file.
    private func symbols(in relativePath: String, arguments: [String] = []) throws -> Set<String> {
        try Set(currentSymbols(in: relativePath, arguments: arguments).map(\.name))
    }

    private func usrs(named name: String, in relativePath: String) throws -> Set<String> {
        try Set(currentSymbols(in: relativePath).filter { $0.name == name }.map(\.usr))
    }

    private func currentSymbols(in relativePath: String, arguments: [String] = []) throws -> [(name: String, usr: String)] {
        let store = try IndexStore(path: freshness(arguments: arguments).storePath.string)
        let file = root.appending(relativePath).url.resolvingSymlinksInPath()
        var result: [(name: String, usr: String)] = []
        for unit in store.units where URL(fileURLWithPath: unit.mainFile).resolvingSymlinksInPath() == file {
            for recordName in unit.recordNames {
                let record = try RecordReader(indexStore: store, recordName: recordName)
                record.forEach(symbol: { result.append(($0.name, $0.usr)) })
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
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(old), "\(relativePath) does not contain \(old)")
        try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Records every command so tests can tell a reuse from a clean.
private final class RecordingShell: Shell {
    private let shell: Shell
    private let commands = Mutex<[[String]]>([])

    init(_ shell: Shell) {
        self.shell = shell
    }

    var cleaned: Bool {
        commands.withLock { $0.contains { $0.starts(with: ["swift", "package", "clean"]) } }
    }

    func reset() {
        commands.withLock { $0.removeAll() }
    }

    @discardableResult
    func exec(_ args: [String]) throws -> String {
        commands.withLock { $0.append(args) }
        return try shell.exec(args)
    }

    func execStatus(_ args: [String]) throws -> Int32 {
        commands.withLock { $0.append(args) }
        return try shell.execStatus(args)
    }
}

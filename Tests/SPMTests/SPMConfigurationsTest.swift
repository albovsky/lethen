import Configuration
import Foundation
@testable import ProjectDrivers
import Shared
import SystemPackage
@testable import TestShared
import XCTest

/// `--configurations` builds and scans several SwiftPM configurations together. Every test builds a
/// private copy of IndexStoreDiscoveryProject with a function called only under `#if DEBUG` and one
/// called only without it, so a reference from either configuration is visible.
final class SPMConfigurationsTest: SPMSourceGraphTestCase {
    private static var root: FilePath!

    override static func setUp() {
        super.setUp()
        setupState.capture {
            root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen configurations \(UUID().uuidString)").path)
            try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
            let fixture = ProjectRootPath.appending("Tests/IndexStoreDiscoveryProject")
            for input in ["Package.swift", "Sources"] {
                try FileManager.default.copyItem(at: fixture.appending(input).url, to: root.appending(input).url)
            }
            try """
            func calledOnlyInRelease() {}
            func calledOnlyInDebug() {}

            public func conditionalEntry() {
                #if DEBUG
                    calledOnlyInDebug()
                #else
                    calledOnlyInRelease()
                #endif
            }

            """.write(toFile: root.appending("Sources/TargetA/Conditional.swift").string, atomically: true, encoding: .utf8)
            try """
            #if DEBUG
                public func branchedEntry(debugUsed: Int, releaseUsed: Int) { print(debugUsed) }
            #else
                public func branchedEntry(debugUsed: Int, releaseUsed: Int) { print(releaseUsed) }
            #endif

            #if DEBUG
                public func unusedInBothEntry(kept: Int, dropped: Int) { print(kept) }
            #else
                public func unusedInBothEntry(kept: Int, dropped: Int) { print(kept + 1) }
            #endif

            #if DEBUG
                public func usedInOneCopyEntry(first: Int, second: Int) { print(first, second) }
            #else
                public func usedInOneCopyEntry(first: Int, second: Int) { print(first) }
            #endif

            #if DEBUG
                public func renamedEntry(x a: Int, y b: Int) { print(a) }
            #else
                public func renamedEntry(x b: Int, y a: Int) { print(b) }
            #endif

            #if DEBUG
                public func ignoredOnLaterCopyEntry(kept: Int, dropped: Int) { print(kept) }
            #else
                // periphery:ignore
                public func ignoredOnLaterCopyEntry(kept: Int, dropped: Int) { print(kept) }
            #endif

            #if DEBUG
                public func ignoredParameterOnLaterCopyEntry(kept: Int, dropped: Int) { print(kept) }
            #else
                // periphery:ignore:parameters dropped
                public func ignoredParameterOnLaterCopyEntry(kept: Int, dropped: Int) { print(kept) }
            #endif

            #if DEBUG
                public func renamedIgnoredEntry(x a: Int, y b: Int) { print(a) }
            #else
                // periphery:ignore:parameters a
                public func renamedIgnoredEntry(x b: Int, y a: Int) { print(b) }
            #endif

            """.write(toFile: root.appending("Sources/TargetA/Branched.swift").string, atomically: true, encoding: .utf8)
            let main = root.appending("Sources/MainTarget/main.swift")
            try (String(contentsOfFile: main.string, encoding: .utf8) + "conditionalEntry()\nbranchedEntry(debugUsed: 1, releaseUsed: 2)\nignoredParameterOnLaterCopyEntry(kept: 1, dropped: 2)\nunusedInBothEntry(kept: 1, dropped: 2)\nrenamedIgnoredEntry(x: 1, y: 2)\nusedInOneCopyEntry(first: 1, second: 2)\nrenamedEntry(x: 1, y: 2)\n")
                .write(toFile: main.string, atomically: true, encoding: .utf8)
        }
    }

    override static func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root.url)
        }
        super.tearDown()
    }

    func testDebugOnlyScanReportsReleaseOnlyCallee() throws {
        let configuration = Self.configuration([])
        try Self.build(projectPath: Self.root, configuration: configuration)
        try Self.index(configuration: configuration)
        assertReferenced(.functionFree("calledOnlyInDebug()"))
        assertNotReferenced(.functionFree("calledOnlyInRelease()"))
    }

    func testBothConfigurationsUnionReferences() throws {
        let configuration = Self.configuration(["debug", "release"])
        try Self.build(projectPath: Self.root, configuration: configuration)
        try Self.index(configuration: configuration)
        assertReferenced(.functionFree("calledOnlyInDebug()"))
        assertReferenced(.functionFree("calledOnlyInRelease()"))
    }

    /// The same function declared in both branches of `#if DEBUG` is indexed from both configurations
    /// with one USR per declaration. Each parameter is used in one configuration, so neither is reported.
    func testSameUSRDeclarationsFromBothConfigurationsAreMerged() throws {
        let configuration = Self.configuration(["debug", "release"])
        try Self.build(projectPath: Self.root, configuration: configuration)
        try Self.index(configuration: configuration)
        let unusedParameters = Self.results.flatMap(\.usrs).filter { $0.contains("branchedEntry") || $0.contains("unusedInBothEntry") && !$0.hasPrefix("param-dropped") }.sorted()
        XCTAssertEqual(unusedParameters, [String]())

        // Control: a parameter unused in every configuration is still reported, once.
        let droppedParameters = Self.results.flatMap(\.usrs).filter { $0.hasPrefix("param-dropped-unusedInBothEntry") }
        XCTAssertEqual(droppedParameters.count, 1)

        // Controls: the copy that uses every parameter keeps `second` used, and copies that name their parameters
        // differently are compared by position, so the second one is reported once.
        let usedInOneCopy = Self.results.flatMap(\.usrs).filter { $0.contains("usedInOneCopyEntry") }
        XCTAssertEqual(usedInOneCopy, [String]())
        // A `periphery:ignore` command on a copy the graph did not keep still applies to the kept copy's parameters,
        // and the parameter command is not reported as superfluous.
        let ignored = Self.results.flatMap(\.usrs).filter { $0.contains("OnLaterCopyEntry") }
        XCTAssertEqual(ignored, [String]())
        // Ignoring a parameter by the local name one copy gives it retains the kept copy's parameter, unreported
        // and not flagged as a superfluous ignore.
        let renamedIgnored = Self.results.flatMap(\.usrs).filter { $0.contains("renamedIgnoredEntry") }
        XCTAssertEqual(renamedIgnored, [String]())
        let renamed = Self.results.flatMap(\.usrs).filter { $0.contains("renamedEntry") }
        XCTAssertEqual(renamed.count, 1)
        XCTAssertTrue(renamed.first?.hasPrefix("param-b-renamedEntry") ?? false, "\(renamed)")
    }

    /// `swift package clean` removes every configuration's products. When a later configuration's
    /// build has to clean, the configurations built before it must be rebuilt, not scanned from a
    /// store that no longer exists.
    func testConfigurationCleanedByALaterBuildIsRebuilt() throws {
        // Release first, then debug: debug's stamp postdates every release object, so debug is
        // reused below, while release finds debug's newer objects in the shared build tree and cleans.
        try Self.build(projectPath: Self.root, configuration: Self.configuration(["release"]))
        try Self.build(projectPath: Self.root, configuration: Self.configuration(["debug"]))

        let configuration = Self.configuration(["debug", "release"])
        try Self.build(projectPath: Self.root, configuration: configuration)
        try Self.index(configuration: configuration)
        assertReferenced(.functionFree("calledOnlyInDebug()"))
        assertReferenced(.functionFree("calledOnlyInRelease()"))
    }

    /// A configuration that does not build must fail the scan, never leave one configuration scanned.
    func testFailingConfigurationBuildThrows() throws {
        let failing = Self.root.appending("Sources/TargetA/ReleaseOnlyError.swift")
        try "#if !DEBUG\n    #error(\"fails only in release\")\n#endif\n".write(toFile: failing.string, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: failing.string) }

        XCTAssertThrowsError(try Self.build(projectPath: Self.root, configuration: Self.configuration(["debug", "release"])))
    }

    func testRejectsUnknownConfiguration() {
        XCTAssertThrowsError(try SPMProjectDriver(configuration: Self.configuration(["profile"]), shell: Self.shell, logger: Self.logger)) { error in
            guard case LethenError.usageError = error else { return XCTFail("\(error)") }
        }
    }

    func testRejectsConfigurationInBuildArguments() {
        for arguments in [["-c", "release"], ["--configuration", "release"], ["--configuration=release"]] {
            let configuration = Self.configuration(["debug"])
            configuration.buildArguments = arguments
            XCTAssertThrowsError(try SPMProjectDriver(configuration: configuration, shell: Self.shell, logger: Self.logger)) { error in
                guard case LethenError.usageError = error else { return XCTFail("\(arguments): \(error)") }
            }
        }
    }

    // MARK: - Private

    private static func configuration(_ configurations: [String]) -> Configuration {
        let configuration = Configuration()
        configuration.quiet = true
        configuration.configurations = configurations
        return configuration
    }
}

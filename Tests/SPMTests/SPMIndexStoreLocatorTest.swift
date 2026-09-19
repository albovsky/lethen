import Configuration
import Foundation
import Logger
@testable import ProjectDrivers
import Shared
import SystemPackage
import XCTest

final class SPMIndexStoreLocatorTest: XCTestCase {
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    func testStoreLayoutUsesActiveBinaryDirectory() throws {
        let cases = [
            ("/pkg/.build/out/Products/Debug", "/pkg/.build/out/Products/Debug/index/store"),
            ("/pkg/.build/out/Products/Release", "/pkg/.build/out/Products/Release/index/store"),
            ("/tmp/Build Space/out/Products/Debug", "/tmp/Build Space/out/Products/Debug/index/store"),
            ("/pkg/.build/arm64-apple-macosx/debug", "/pkg/.build/arm64-apple-macosx/debug/index/store"),
            ("/pkg/.build/x86_64-unknown-linux-gnu/release", "/pkg/.build/x86_64-unknown-linux-gnu/release/index/store"),
        ]
        for (binary, store) in cases {
            XCTAssertEqual(try SPMIndexStoreLocator.indexStorePath(binPath: FilePath(binary)), FilePath(store))
        }
    }

    func testRejectsInvalidQueryOutputWithContext() {
        for output in ["", "relative/debug", "warning: hello\n/pkg/debug", "/pkg/debug\n/pkg/release", "OVERVIEW: Build sources"] {
            let pkg = SPM.Package(configuration: Configuration(), shell: ExpectedCommandShell(
                command: ["swift", "build", "--show-bin-path", "--help", "--enable-index-store"], output: output
            ), logger: logger)
            XCTAssertThrowsError(try pkg.indexStorePath(additionalArguments: ["--help"])) {
                let message = String(describing: $0)
                XCTAssertTrue(message.contains("--show-bin-path"))
                XCTAssertTrue(output.isEmpty ? message.contains("received:") : message.contains(output), message)
            }
        }
    }

    func testForwardsBuildSelectionAndDoesNotUseAlternateStore() throws {
        try withTemporaryDirectory { root in
            let native = root.appending("arm64-apple-macosx/release/index/store")
            try FileManager.default.createDirectory(at: native.url, withIntermediateDirectories: true)
            let arguments = ["-c", "release", "--scratch-path", "'\(root.string)'", "--arch", "arm64", "--sdk", "macosx", "--build-system", "swiftbuild"]
            let pkg = SPM.Package(configuration: Configuration(), shell: ExpectedCommandShell(
                command: ["swift", "build", "--show-bin-path"] + arguments + ["--enable-index-store"],
                output: "\(root.string)/out/Products/Release\n"
            ), logger: logger)
            XCTAssertThrowsError(try pkg.indexStorePath(additionalArguments: arguments)) {
                XCTAssertTrue(String(describing: $0).contains(root.appending("out/Products/Release/index/store").string))
                XCTAssertTrue(String(describing: $0).contains("--index-store-path"))
            }
            try FileManager.default.createDirectory(at: root.appending("out/Products/Release/index/store").url, withIntermediateDirectories: true)
            XCTAssertEqual(try pkg.indexStorePath(additionalArguments: arguments), root.appending("out/Products/Release/index/store"))
        }
    }

    func testManagedReleaseBuildEnablesIndexing() throws {
        let arguments = ["-c", "release", "--scratch-path", "'/tmp/Build Space'"]
        let binary = "/tmp/lethen-unbuilt-\(UUID().uuidString)/out/Products/Release"
        let query = ["swift", "build", "--show-bin-path"] + arguments + ["--enable-index-store"]
        let build = ["swift", "build", "--build-tests"] + arguments + [
            "--enable-index-store", "-Xswiftc", "-index-store-path", "-Xswiftc", "'\(binary)/index/store'",
        ]
        let pkg = SPM.Package(configuration: Configuration(), shell: ExpectedCommandShell(
            responses: [query: binary, build: ""]
        ), logger: logger)
        try pkg.build(additionalArguments: arguments)
    }

    func testManagedBuildRejectsDisabledIndexingBeforeInvokingShell() {
        let pkg = SPM.Package(configuration: Configuration(), shell: ExpectedCommandShell(command: [], output: ""), logger: logger)
        XCTAssertThrowsError(try pkg.build(additionalArguments: ["--disable-index-store"])) {
            XCTAssertTrue(String(describing: $0).contains("--disable-index-store"))
            XCTAssertTrue(String(describing: $0).contains("--skip-build"))
        }
    }

    func testCleanForwardsOnlyScratchPath() throws {
        for scratch in [["--scratch-path", "'/tmp/Build Space'"], ["--scratch-path='/tmp/Build Space'"]] {
            let pkg = SPM.Package(configuration: Configuration(), shell: ExpectedCommandShell(
                command: ["swift", "package", "clean"] + scratch, output: ""
            ), logger: logger)
            try pkg.clean(additionalArguments: ["-c", "release"] + scratch + ["--build-system", "native"])
        }
    }

    func testExplicitStoresAndExternalManifestSkipAllSubprocesses() throws {
        try withTemporaryDirectory { root in
            let stores = [root.appending("one"), root.appending("two")]
            for store in stores {
                for directory in ["v5/records", "v5/units"] {
                    try FileManager.default.createDirectory(at: store.appending(directory).url, withIntermediateDirectories: true)
                }
            }
            let manifest = root.appending("package.json")
            try Data(#"{"targets":[]}"#.utf8).write(to: manifest.url)
            let configuration = Configuration()
            configuration.skipBuild = true
            configuration.indexStorePath = stores
            configuration.jsonPackageManifestPath = manifest
            let driver = try SPMProjectDriver(configuration: configuration,
                                              shell: ExpectedCommandShell(command: [], output: ""), logger: logger)
            try driver.build()
            XCTAssertTrue(try driver.plan(logger: logger.contextualized(with: "test")).sourceFiles.isEmpty)
            // Both explicit stores must be consumed, not only the first one.
            try FileManager.default.removeItem(at: stores[1].url)
            XCTAssertThrowsError(try driver.plan(logger: logger.contextualized(with: "test")))
        }
    }

    private func withTemporaryDirectory(_ body: (FilePath) throws -> Void) throws {
        let root = FilePath(FileManager.default.temporaryDirectory.appendingPathComponent("lethen discovery \(UUID().uuidString)").path)
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.url) }
        try body(root)
    }
}

private struct ExpectedCommandShell: Shell {
    let responses: [[String]: String]

    init(command: [String], output: String) {
        responses = [command: output]
    }

    init(responses: [[String]: String]) {
        self.responses = responses
    }

    func exec(_ args: [String]) throws -> String {
        guard let output = responses[args] else {
            throw PeripheryError.packageError(message: "Unexpected subprocess: \(args)")
        }

        return output
    }

    func execStatus(_ args: [String]) throws -> Int32 {
        _ = try exec(args)
        return 0
    }
}

@testable import ProjectDrivers
import SourceGraph
import SystemPackage
import XCTest

final class UnscannedTargetWarningTest: XCTestCase {
    private func target(_ name: String, shared: [String] = []) -> UnscannedTarget {
        UnscannedTarget(
            name: name,
            swiftSourceFiles: Set((["\(name).swift"] + shared).map { FilePath("/p/\($0)") }),
            sharedSourceFiles: Set(shared.map { FilePath("/p/\($0)") })
        )
    }

    func testNamesTheDependencyAndWhatHappens() throws {
        let warning = try XCTUnwrap(XcodeProjectDriver.unscannedTargetWarning(for: target("WidgetsExtension"), scannedDependencies: ["WMF"]))

        XCTAssertEqual(
            warning,
            "Target WidgetsExtension is in the project but not built by the scanned schemes, and it depends on WMF, so its uses of scanned code are invisible; declarations it names are reported as likely rather than certain. Add a scheme that builds it to --schemes to scan it, or pass --exclude-targets WidgetsExtension to silence this."
        )
    }

    func testCountsTheFilesTheScannedTargetsCompile() throws {
        let one = try XCTUnwrap(XcodeProjectDriver.unscannedTargetWarning(for: target("Ext", shared: ["A.swift"]), scannedDependencies: []))
        XCTAssertTrue(one.contains("and it compiles 1 file the scanned targets compile, so"), one)
        XCTAssertFalse(one.contains("depends on"), one)

        let three = try XCTUnwrap(XcodeProjectDriver.unscannedTargetWarning(for: target("Ext", shared: ["A.swift", "B.swift", "C.swift"]), scannedDependencies: []))
        XCTAssertTrue(three.contains("it compiles 3 files the scanned targets compile"), three)
    }

    func testNamesBothTies() throws {
        let warning = try XCTUnwrap(XcodeProjectDriver.unscannedTargetWarning(for: target("WidgetsExtension", shared: ["A.swift", "B.swift", "C.swift"]), scannedDependencies: ["WMF", "Core"]))

        XCTAssertTrue(warning.contains("it depends on WMF, Core and compiles 3 files the scanned targets compile, so its uses"), warning)
        XCTAssertTrue(warning.contains("--exclude-targets WidgetsExtension"), warning)
    }

    func testNoWarningForATargetThatUsesNothingScanned() {
        XCTAssertNil(XcodeProjectDriver.unscannedTargetWarning(for: target("Standalone"), scannedDependencies: []))
        XCTAssertEqual(
            XcodeProjectDriver.unscannedTargetWarnings(for: [target("Standalone")], scannedDependencies: [:]),
            []
        )
    }

    func testWarningsAreSortedByTargetNameAndSkipTargetsWithoutATie() {
        let warnings = XcodeProjectDriver.unscannedTargetWarnings(
            for: [target("Zed"), target("Standalone"), target("Alpha")],
            scannedDependencies: ["Zed": ["WMF"], "Alpha": ["WMF"]]
        )

        XCTAssertEqual(warnings.count, 2)
        XCTAssertTrue(warnings[0].hasPrefix("Target Alpha "), warnings[0])
        XCTAssertTrue(warnings[1].hasPrefix("Target Zed "), warnings[1])
    }

    func testQuotesTheTargetNameInTheExcludeFlag() throws {
        let warning = try XCTUnwrap(XcodeProjectDriver.unscannedTargetWarning(for: target("Wikipedia Stickers"), scannedDependencies: ["WMF"]))

        XCTAssertTrue(warning.contains("--exclude-targets 'Wikipedia Stickers' to silence"), warning)
    }

    /// `App` depends on the unscanned `Bridge`, which depends on the scanned `Core` and may re-export it.
    func testScannedDependenciesAreReachedThroughUnscannedTargets() {
        let dependencies: [String: Set<String>] = ["App": ["Bridge", "Tests"], "Bridge": ["Core", "App"], "Tests": [], "Core": ["Base"]]
        let scanned: Set<String> = ["Core", "Base"]

        XCTAssertEqual(XcodeProjectDriver.scannedDependencies(of: "App", dependencies: dependencies, scanned: scanned), ["Core"])
        XCTAssertEqual(XcodeProjectDriver.scannedDependencies(of: "Bridge", dependencies: dependencies, scanned: scanned), ["Core"])
        XCTAssertEqual(XcodeProjectDriver.scannedDependencies(of: "Tests", dependencies: dependencies, scanned: scanned), [])
    }
}

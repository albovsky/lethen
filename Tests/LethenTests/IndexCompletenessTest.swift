import Indexer
import Shared
import SystemPackage
import XCTest

final class IndexCompletenessTest: XCTestCase {
    private func path(_ name: String) -> FilePath {
        FilePath("/p/\(name)")
    }

    private func target(_ modules: [String], _ files: [String]) -> IndexCompleteness.Target {
        .init(moduleNames: Set(modules), sourceFiles: Set(files.map(path)))
    }

    private func units(_ units: [String: [String]]) -> [FilePath: Set<String>] {
        Dictionary(uniqueKeysWithValues: units.map { (path($0.key), Set($0.value)) })
    }

    /// The built target's shared file has a unit of the built target's module; the unbuilt target has none of its own.
    func testUnbuiltTargetSharingAFileWithABuiltOneIsNotIndexed() {
        let targets = [
            "A": target(["A"], ["A.swift", "Shared.swift"]),
            "B": target(["B"], ["Shared.swift", "B.swift"]),
        ]
        let modules = units(["A.swift": ["A"], "Shared.swift": ["A"]])

        XCTAssertEqual(IndexCompleteness.missingFiles(byTarget: targets, indexedModules: modules), [])
        XCTAssertEqual(IndexCompleteness.indexedFiles(byTarget: targets, indexedModules: modules)["B"], [])
        XCTAssertEqual(IndexCompleteness.indexedFiles(byTarget: targets, indexedModules: modules)["A"], [path("A.swift"), path("Shared.swift")])
    }

    /// Two targets of one module name that share a file: the shared unit proves neither, and counts as present.
    func testSharedUnitOfASharedModuleIsNotMissing() {
        let targets = [
            "A": target(["Core"], ["Shared.swift", "OnlyA.swift"]),
            "B": target(["Core"], ["Shared.swift", "OnlyB.swift"]),
        ]
        let modules = units(["Shared.swift": ["Core"], "OnlyA.swift": ["Core"]])

        XCTAssertEqual(IndexCompleteness.missingFiles(byTarget: targets, indexedModules: modules), [])
    }

    func testFileOfABuiltTargetWithoutAUnitIsMissing() {
        let targets = ["A": target(["A"], ["A.swift", "Extra.swift"])]

        XCTAssertEqual(IndexCompleteness.missingFiles(byTarget: targets, indexedModules: units(["A.swift": ["A"]])), [path("Extra.swift")])
    }

    /// B's compile of the shared file was a cache hit: only A's unit exists, so B is missing its own.
    func testSharedFileWhoseUnitBelongsOnlyToTheOtherTargetIsMissing() {
        let targets = [
            "A": target(["A"], ["Shared.swift", "OnlyA.swift"]),
            "B": target(["B"], ["Shared.swift", "OnlyB.swift"]),
        ]
        let modules = units(["Shared.swift": ["A"], "OnlyA.swift": ["A"], "OnlyB.swift": ["B"]])

        XCTAssertEqual(IndexCompleteness.missingFiles(byTarget: targets, indexedModules: modules), [path("Shared.swift")])
    }

    func testUnitOfAModuleNoTargetClaimsCountsAsPresent() {
        let targets = ["A": target(["A"], ["A.swift", "Impl.m"])]

        XCTAssertEqual(IndexCompleteness.missingFiles(byTarget: targets, indexedModules: units(["A.swift": ["A"], "Impl.m": ["Impl"]])), [])
    }

    /// A clang unit names no module, so one for a file both targets compile cannot show that the unbuilt target was
    /// built; its own files are not missing.
    func testTargetWhoseOnlyEvidenceIsAnUnclaimedSharedUnitIsLeftAlone() {
        let targets = [
            "A": target(["A"], ["A.swift", "Shared.m"]),
            "B": target(["B"], ["B.swift", "Shared.m"]),
        ]
        let modules = units(["A.swift": ["A"], "Shared.m": []])

        XCTAssertEqual(IndexCompleteness.missingFiles(byTarget: targets, indexedModules: modules), [])
        XCTAssertEqual(IndexCompleteness.indexedFiles(byTarget: targets, indexedModules: modules)["B"], [path("Shared.m")])
    }

    func testTargetWithNoUnitOfItsOwnIsLeftAlone() {
        let targets = ["A": target(["A"], ["A.swift"])]

        XCTAssertEqual(IndexCompleteness.missingFiles(byTarget: targets, indexedModules: [:]), [])
    }

    func testCheckThrowsWithTheStoreAndSortedFiles() {
        let targets = ["A": target(["A"], ["A.swift", "Z.swift", "M.swift"])]

        XCTAssertThrowsError(try IndexCompleteness.check(byTarget: targets, indexedModules: units(["A.swift": ["A"]]), store: path("Store"))) { error in
            guard case let LethenError.incompleteIndexStore(store, files) = error else { return XCTFail("\(error)") }

            XCTAssertEqual(store, "/p/Store")
            XCTAssertEqual(files, ["/p/M.swift", "/p/Z.swift"])
            XCTAssertTrue("\(error)".contains("is incomplete: 2 source files of indexed targets have no index unit (/p/M.swift, /p/Z.swift)"))
        }
    }

    func testCheckDoesNotThrowWhenNothingIsMissing() throws {
        let targets = ["A": target(["A"], ["A.swift"])]

        try IndexCompleteness.check(byTarget: targets, indexedModules: units(["A.swift": ["A"]]), store: path("Store"))
    }
}

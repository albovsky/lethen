import Configuration
import Foundation
import Logger
@testable import PeripheryKit
@testable import SourceGraph
import SystemPackage
import XCTest

final class OutputDeclarationFilterTest: XCTestCase {
    private let root = FilePath.current
    private let logger = Logger(quiet: true, verbose: false, colorMode: .never)

    func testBaselineDropsResultsWhoseSymbolIsListed() throws {
        let kept = result(name: "Kept", usr: "s:Kept")
        let baselined = result(name: "Old", usr: "s:Old")
        let filtered = try filter([kept, baselined], configuration: Configuration(), baseline: .v1(usrs: ["s:Old"]))
        XCTAssertEqual(filtered.map(\.declaration.name), ["Kept"])
    }

    func testSuperfluousIgnoreResultsAreKeyedSeparatelyFromTheirDeclaration() throws {
        let superfluous = result(name: "Ignored", usr: "s:Ignored", annotation: .superfluousIgnoreCommand)
        XCTAssertEqual(superfluous.usrs, ["superfluous-ignore-s:Ignored"])
        let notFiltered = try filter([superfluous], configuration: Configuration(), baseline: .v1(usrs: ["s:Ignored"]))
        XCTAssertEqual(notFiltered.count, 1)
        let filtered = try filter([superfluous], configuration: Configuration(), baseline: .v1(usrs: ["superfluous-ignore-s:Ignored"]))
        XCTAssertTrue(filtered.isEmpty)
    }

    func testReportExcludeDropsMatchingFiles() throws {
        let configuration = Configuration()
        configuration.reportExclude = ["Sources/Generated/*.swift"]
        configuration.buildFilenameMatchers()
        let generated = result(name: "Generated", usr: "s:Generated", path: "Sources/Generated/G.swift")
        let handwritten = result(name: "Handwritten", usr: "s:Handwritten", path: "Sources/A.swift")
        let filtered = try filter([generated, handwritten], configuration: configuration, baseline: nil)
        XCTAssertEqual(filtered.map(\.declaration.name), ["Handwritten"])
    }

    func testReportIncludeSupersedesReportExclude() throws {
        let configuration = Configuration()
        configuration.reportExclude = ["Sources/**/*.swift"]
        configuration.reportInclude = ["Sources/A.swift"]
        configuration.buildFilenameMatchers()
        let included = result(name: "Included", usr: "s:Included", path: "Sources/A.swift")
        let other = result(name: "Other", usr: "s:Other", path: "Sources/B.swift")
        let filtered = try filter([other, included], configuration: configuration, baseline: nil)
        XCTAssertEqual(filtered.map(\.declaration.name), ["Included"])
    }

    func testResultsAreSortedByLocation() throws {
        let later = result(name: "Later", usr: "s:Later", path: "Sources/B.swift", line: 1)
        let earlierFile = result(name: "EarlierFile", usr: "s:EarlierFile", path: "Sources/A.swift", line: 20)
        let earlierLine = result(name: "EarlierLine", usr: "s:EarlierLine", path: "Sources/A.swift", line: 2)
        let filtered = try filter([later, earlierFile, earlierLine], configuration: Configuration(), baseline: nil)
        XCTAssertEqual(filtered.map(\.declaration.name), ["EarlierLine", "EarlierFile", "Later"])
    }

    // MARK: - Private

    private func filter(_ results: [ScanResult], configuration: Configuration, baseline: Baseline?) throws -> [ScanResult] {
        try OutputDeclarationFilter(configuration: configuration, logger: logger).filter(results, with: baseline)
    }

    private func result(name: String, usr: String, path: String = "Sources/A.swift", line: Int = 1, annotation: ScanResult.Annotation = .unused) -> ScanResult {
        let location = Location(file: SourceFile(path: root.appending(path), modules: ["App"]), line: line, column: 1)
        let declaration = Declaration(name: name, kind: .class, usrs: [usr], location: location)
        return ScanResult(declaration: declaration, annotation: annotation)
    }
}

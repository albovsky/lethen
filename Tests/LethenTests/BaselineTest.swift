import Configuration
import Foundation
import Logger
@testable import PeripheryKit
@testable import SourceGraph
import SystemPackage
import XCTest

final class BaselineTest: XCTestCase {
    func testDecodesVersionOneFile() throws {
        let json = Data(#"{"v1":{"usrs":["s:Old","s:Older"]}}"#.utf8)
        let baseline = try JSONDecoder().decode(Baseline.self, from: json)
        XCTAssertEqual(baseline.usrs, ["s:Old", "s:Older"])
    }

    func testRoundTripsThroughJson() throws {
        let baseline = Baseline.v1(usrs: ["s:One", "s:Two"])
        let data = try JSONEncoder().encode(baseline)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v1"])
        XCTAssertEqual(try JSONDecoder().decode(Baseline.self, from: data).usrs, ["s:One", "s:Two"])
    }

    func testRejectsUnknownVersion() {
        let json = Data(#"{"v2":{"usrs":[]}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Baseline.self, from: json))
    }

    /// Baselines are USR sets: a result's confidence must never change what a baseline filters.
    func testBaselineFiltersResultsRegardlessOfConfidence() throws {
        let location = Location(file: SourceFile(path: FilePath.current.appending("Sources/A.swift"), modules: ["App"]), line: 1, column: 1)
        let likely = ScanResult(
            declaration: Declaration(name: "Dynamic", kind: .functionMethodInstance, usrs: ["s:Dynamic"], location: location),
            annotation: .unused,
            confidence: .likely,
            confidenceReason: "its name appears in a string literal"
        )
        let certain = ScanResult(
            declaration: Declaration(name: "Plain", kind: .class, usrs: ["s:Plain"], location: location),
            annotation: .unused
        )

        // Written the way `--write-baseline` writes it, and as a 3.9 baseline would record the same symbols.
        let written = Baseline.v1(usrs: [likely, certain].flatMapSet(\.usrs).sorted())
        let decoded = try JSONDecoder().decode(Baseline.self, from: JSONEncoder().encode(written))
        XCTAssertEqual(Set(decoded.usrs), ["s:Dynamic", "s:Plain"])

        let filter = OutputDeclarationFilter(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        XCTAssertTrue(try filter.filter([likely, certain], with: decoded).isEmpty)
    }
}

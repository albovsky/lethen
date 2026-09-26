import Foundation
@testable import PeripheryKit
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
}
